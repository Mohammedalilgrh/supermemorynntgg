# ─────────────────────────────────────────────────────────────
# STAGE 1: Alpine tools builder
# ─────────────────────────────────────────────────────────────
FROM alpine:3.20 AS tools

RUN apk add --no-cache \
      curl \
      tar \
      xz \
      coreutils \
      findutils \
      bash \
      jq \
      sqlite \
      python3 \
      py3-pip \
      ca-certificates \
      fontconfig \
      ttf-dejavu \
      font-noto \
      font-noto-arabic \
      font-noto-extra \
      libass \
      fribidi \
      harfbuzz \
      freetype \
      libstdc++ \
      libgcc \
      zlib \
      expat

# Collect shell tool binaries into /toolbox
RUN mkdir -p /toolbox && \
    for cmd in \
      curl bash jq sqlite3 python3 \
      split sha256sum stat du sort tail \
      awk xargs find wc cut tr cat date sleep \
      mkdir rm ls grep sed head touch cp mv \
      basename expr base64 fc-cache fc-list; do \
      p="$(which $cmd 2>/dev/null)" && \
        [ -f "$p" ] && cp "$p" /toolbox/ || true; \
    done

# Show what python paths actually exist (for debugging)
RUN echo "=== Python paths in Alpine ===" && \
    find /usr -name "python*" -type f 2>/dev/null | head -20 && \
    echo "=== Python lib dirs ===" && \
    ls /usr/lib/ | grep -i python && \
    echo "=== Python version ===" && \
    python3 --version

# Download ffmpeg static binary
RUN curl -L -o /tmp/ffmpeg.tar.xz \
      https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz && \
    tar -xJf /tmp/ffmpeg.tar.xz -C /tmp/ && \
    cp /tmp/ffmpeg-*-static/ffmpeg  /toolbox/ && \
    cp /tmp/ffmpeg-*-static/ffprobe /toolbox/ && \
    rm -rf /tmp/ffmpeg-*-static /tmp/ffmpeg.tar.xz && \
    /toolbox/ffmpeg -version | head -1

# Build font cache
RUN fc-cache -fv 2>/dev/null || true

# ─────────────────────────────────────────────────────────────
# STAGE 2: Final n8n hardened image
# ─────────────────────────────────────────────────────────────
FROM docker.n8n.io/n8nio/n8n:2.6.4

USER root

# ── Copy all binaries ─────────────────────────────────────────
COPY --from=tools /toolbox/ /usr/local/bin/

# ── Copy Python libs (Alpine stores in /usr/lib/python3.X) ───
# Use wildcard via shell — copy entire python lib directory
COPY --from=tools /usr/lib/ /usr/lib.tools/

# ── Copy fonts ───────────────────────────────────────────────
COPY --from=tools /usr/share/fonts/      /usr/share/fonts/
COPY --from=tools /usr/share/fontconfig/ /usr/share/fontconfig/
COPY --from=tools /etc/fonts/            /etc/fonts/
COPY --from=tools /var/cache/fontconfig/ /var/cache/fontconfig/

# ── Copy SSL certs ───────────────────────────────────────────
COPY --from=tools /etc/ssl/certs/ /etc/ssl/certs/

# ── Copy musl libc (Alpine's C library) ──────────────────────
COPY --from=tools /lib/ /lib.tools/

# ── Merge copied libs into correct locations ─────────────────
RUN cp -rn /usr/lib.tools/* /usr/lib/ 2>/dev/null || true && \
    cp -rn /lib.tools/*     /lib/     2>/dev/null || true && \
    rm -rf /usr/lib.tools /lib.tools

# ── Set environment variables ────────────────────────────────
ENV FFMPEG_PATH="/usr/local/bin/ffmpeg"
ENV FFPROBE_PATH="/usr/local/bin/ffprobe"
ENV FFREPORT="file=/tmp/ffreport-%p-%t.log:level=32"
ENV PATH="/usr/local/bin:$PATH"
ENV LD_LIBRARY_PATH="/usr/lib:/usr/local/lib:$LD_LIBRARY_PATH"

# ── Auto-detect Python version and set PYTHONPATH ────────────
RUN PYVER=$(ls /usr/lib/ | grep "^python3\." | head -1) && \
    echo "Detected Python version dir: $PYVER" && \
    echo "export PYTHONPATH=/usr/lib/${PYVER}" >> /etc/environment && \
    echo "PYVER=${PYVER}" > /tmp/pyver.env

# ── Create all symlinks ──────────────────────────────────────
RUN ln -sf /usr/local/bin/python3  /usr/bin/python3  2>/dev/null || true && \
    ln -sf /usr/local/bin/python3  /usr/bin/python   2>/dev/null || true && \
    ln -sf /usr/local/bin/python3  /bin/python3      2>/dev/null || true && \
    ln -sf /usr/local/bin/python3  /bin/python       2>/dev/null || true && \
    ln -sf /usr/local/bin/ffmpeg   /usr/bin/ffmpeg   2>/dev/null || true && \
    ln -sf /usr/local/bin/ffprobe  /usr/bin/ffprobe  2>/dev/null || true && \
    ln -sf /usr/local/bin/ffmpeg   /bin/ffmpeg       2>/dev/null || true && \
    ln -sf /usr/local/bin/ffprobe  /bin/ffprobe      2>/dev/null || true && \
    ln -sf /usr/local/bin/bash     /bin/bash         2>/dev/null || true && \
    chmod +x \
      /usr/local/bin/ffmpeg \
      /usr/local/bin/ffprobe \
      /usr/local/bin/python3 \
      /usr/local/bin/bash    \
      2>/dev/null || true

# ── Test Python works with correct lib path ──────────────────
RUN PYVER=$(ls /usr/lib/ | grep "^python3\." | head -1) && \
    PYTHONPATH="/usr/lib/${PYVER}" /usr/local/bin/python3 --version && \
    PYTHONPATH="/usr/lib/${PYVER}" /usr/local/bin/python3 -c "print('Python3 OK')" && \
    echo "Python PYVER=${PYVER} works"

# ── Set PYTHONPATH permanently based on detected version ─────
RUN PYVER=$(ls /usr/lib/ | grep "^python3\." | head -1) && \
    echo "ENV PYTHONPATH=/usr/lib/${PYVER}" && \
    printf 'export PYTHONPATH=/usr/lib/%s\n' "${PYVER}" >> /etc/profile && \
    printf 'export PYTHONPATH=/usr/lib/%s\n' "${PYVER}" >> /root/.bashrc  && \
    printf 'export PYTHONPATH=/usr/lib/%s\n' "${PYVER}" >> /home/node/.bashrc 2>/dev/null || true

# Hardcode PYTHONPATH for the detected version
RUN PYVER=$(ls /usr/lib/ | grep "^python3\." | head -1) && \
    echo "Detected: ${PYVER}" && \
    echo "${PYVER}" > /tmp/detected_pyver

ENV PYTHONPATH="/usr/lib/python3.12:/usr/lib/python3"

# ── Directories + permissions ────────────────────────────────
RUN mkdir -p \
      /tmp/ffmpeg-temp \
      /tmp/ffmpeg-cache \
      /var/log/ffmpeg \
      /scripts \
      /backup-data \
      /home/node/.n8n && \
    chmod 1777 /tmp/ffmpeg-temp /tmp/ffmpeg-cache /tmp && \
    chmod 755  /var/log/ffmpeg && \
    chown -R node:node \
      /home/node/.n8n \
      /scripts \
      /backup-data \
      /tmp/ffmpeg-temp \
      /tmp/ffmpeg-cache \
      /var/log/ffmpeg

# ── Install n8n community nodes ──────────────────────────────
USER node

RUN cd /home/node/.n8n && \
    mkdir -p nodes && \
    cd nodes && \
    npm init -y 2>/dev/null && \
    npm install @mookielianhd/n8n-nodes-instagram 2>/dev/null || true

USER root

# ── Copy startup scripts ─────────────────────────────────────
COPY --chown=node:node scripts/ /scripts/

RUN sed -i 's/\r$//' /scripts/*.sh 2>/dev/null || true && \
    chmod 0755 /scripts/*.sh

# ── Final verification ───────────────────────────────────────
USER node

RUN /usr/local/bin/ffmpeg -version | head -1 && echo "ffmpeg OK"
RUN /usr/local/bin/ffprobe -version | head -1 && echo "ffprobe OK"
RUN /usr/local/bin/python3 --version && echo "python3 binary OK"
RUN /usr/local/bin/python3 -c "print('Python3 import OK')"
RUN /usr/local/bin/python3 -c "t='d8a8d8b3d985d984d984d987';r=bytes.fromhex(t).decode('utf-8');print('Arabic OK:',r)"
RUN echo "aGVsbG8=" | base64 -d && echo "" && echo "base64 OK"
RUN echo "ALL VERIFIED OK"

WORKDIR /home/node

ENTRYPOINT ["sh", "/scripts/start.sh"]
