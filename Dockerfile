# ─────────────────────────────────────────────────────────────
# STAGE 1: Alpine tools builder
# Install ALL tools here, copy binaries to final image
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
    done && \
    ls -la /toolbox/

# Download ffmpeg static binary
RUN curl -L -o /tmp/ffmpeg.tar.xz \
      https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz && \
    tar -xJf /tmp/ffmpeg.tar.xz -C /tmp/ && \
    cp /tmp/ffmpeg-*-static/ffmpeg  /toolbox/ && \
    cp /tmp/ffmpeg-*-static/ffprobe /toolbox/ && \
    rm -rf /tmp/ffmpeg-*-static /tmp/ffmpeg.tar.xz && \
    /toolbox/ffmpeg -version | head -1

# Build font cache in builder
RUN mkdir -p /etc/fonts && \
    fc-cache -fv 2>/dev/null || true

# ─────────────────────────────────────────────────────────────
# STAGE 2: Final n8n hardened image
# No package manager available — copy everything from builder
# ─────────────────────────────────────────────────────────────
FROM docker.n8n.io/n8nio/n8n:2.6.4

USER root

# ── Copy all binaries from builder ───────────────────────────
COPY --from=tools /toolbox/              /usr/local/bin/

# ── Copy ALL shared libraries from builder ───────────────────
# Python3 libs
COPY --from=tools /usr/lib/python3.12/   /usr/lib/python3.12/
COPY --from=tools /usr/lib/python3/      /usr/lib/python3/
COPY --from=tools /usr/lib/libpython3*   /usr/lib/
# Font libs
COPY --from=tools /usr/lib/libfontconfig* /usr/lib/
COPY --from=tools /usr/lib/libfreetype*   /usr/lib/
COPY --from=tools /usr/lib/libharfbuzz*   /usr/lib/
COPY --from=tools /usr/lib/libfribidi*    /usr/lib/
COPY --from=tools /usr/lib/libass*        /usr/lib/
# C++ runtime
COPY --from=tools /usr/lib/libstdc++*     /usr/lib/
COPY --from=tools /usr/lib/libgcc_s*      /usr/lib/
# Other deps
COPY --from=tools /usr/lib/libexpat*      /usr/lib/
COPY --from=tools /usr/lib/libz*          /usr/lib/
COPY --from=tools /lib/libz*              /usr/lib/
# System libs
COPY --from=tools /lib/ld-musl*           /lib/
COPY --from=tools /lib/libc.musl*         /lib/

# ── Copy fonts ───────────────────────────────────────────────
COPY --from=tools /usr/share/fonts/       /usr/share/fonts/
COPY --from=tools /usr/share/fontconfig/  /usr/share/fontconfig/
COPY --from=tools /etc/fonts/             /etc/fonts/
COPY --from=tools /var/cache/fontconfig/  /var/cache/fontconfig/

# ── Copy SSL certs ───────────────────────────────────────────
COPY --from=tools /etc/ssl/certs/         /etc/ssl/certs/

# ── Copy Python stdlib and site-packages ─────────────────────
COPY --from=tools /usr/lib/python3.12/    /usr/local/lib/python3.12/
COPY --from=tools /usr/share/python3/     /usr/share/python3/

# ── Set environment variables ────────────────────────────────
ENV FFMPEG_PATH="/usr/local/bin/ffmpeg"
ENV FFPROBE_PATH="/usr/local/bin/ffprobe"
ENV FFREPORT="file=/tmp/ffreport-%p-%t.log:level=32"
ENV PATH="/usr/local/bin:$PATH"
ENV LD_LIBRARY_PATH="/usr/lib:/usr/local/lib:$LD_LIBRARY_PATH"
ENV PYTHONPATH="/usr/lib/python3.12:/usr/local/lib/python3.12"
ENV PYTHONHOME="/usr"

# ── Create symlinks ──────────────────────────────────────────
RUN ln -sf /usr/local/bin/python3  /usr/bin/python3    && \
    ln -sf /usr/local/bin/python3  /usr/bin/python     && \
    ln -sf /usr/local/bin/python3  /bin/python3        && \
    ln -sf /usr/local/bin/python3  /bin/python         && \
    ln -sf /usr/local/bin/ffmpeg   /usr/bin/ffmpeg     && \
    ln -sf /usr/local/bin/ffprobe  /usr/bin/ffprobe    && \
    ln -sf /usr/local/bin/ffmpeg   /bin/ffmpeg         && \
    ln -sf /usr/local/bin/ffprobe  /bin/ffprobe        && \
    ln -sf /usr/local/bin/bash     /bin/bash           && \
    chmod +x \
      /usr/local/bin/ffmpeg \
      /usr/local/bin/ffprobe \
      /usr/local/bin/python3 \
      /usr/local/bin/bash

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

RUN /usr/local/bin/ffmpeg  -version | head -1 && echo "ffmpeg  OK"
RUN /usr/local/bin/ffprobe -version | head -1 && echo "ffprobe OK"
RUN /usr/local/bin/python3 --version           && echo "python3 OK"
RUN /usr/local/bin/python3 -c "print('Python3 runtime OK')"
RUN /usr/local/bin/python3 -c "t='d8a8d8b3d985d984d984d987';r=bytes.fromhex(t).decode('utf-8');print('Arabic decode OK:',r)"
RUN echo "aGVsbG8=" | base64 -d && echo "" && echo "base64 OK"
RUN echo "ALL VERIFIED OK"

WORKDIR /home/node

ENTRYPOINT ["sh", "/scripts/start.sh"]
