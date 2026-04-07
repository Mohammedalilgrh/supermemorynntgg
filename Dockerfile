# ─────────────────────────────────────────────────────────────
# Stage 1: Build tools from Alpine
# ─────────────────────────────────────────────────────────────
FROM alpine:3.20 AS tools

# Install all required packages
RUN apk add --no-cache \
      curl jq sqlite tar gzip xz \
      coreutils findutils ca-certificates \
      bash \
      python3 \
      py3-pip \
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
      libgomp \
      zlib \
      expat && \
    mkdir -p /toolbox && \
    for cmd in curl jq sqlite3 split sha256sum \
               stat du sort tail awk xargs find \
               wc cut tr gzip tar cat date sleep \
               mkdir rm ls grep sed head touch \
               cp mv basename expr base64 \
               bash python3 fc-cache fc-list; do \
      p="$(which $cmd 2>/dev/null)" && \
        [ -f "$p" ] && cp "$p" /toolbox/ || true; \
    done

# Copy Python stdlib to /pylib
RUN mkdir -p /pylib && \
    PYVER=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')") && \
    echo "Python version: $PYVER" && \
    cp -r /usr/lib/python${PYVER}/ /pylib/python${PYVER}/ && \
    python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" > /pylib/version.txt && \
    echo "Copied Python ${PYVER} stdlib to /pylib/"

# Build font cache
RUN fc-cache -fv 2>/dev/null || true

# Download ffmpeg static binary
RUN curl -L -o /tmp/ffmpeg.tar.xz https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz && \
    tar -xJf /tmp/ffmpeg.tar.xz -C /tmp/ && \
    cp /tmp/ffmpeg-*-static/ffmpeg /toolbox/ && \
    cp /tmp/ffmpeg-*-static/ffprobe /toolbox/ && \
    rm -rf /tmp/ffmpeg-*-static /tmp/ffmpeg.tar.xz && \
    /toolbox/ffmpeg -version | head -1

# ─────────────────────────────────────────────────────────────
# Stage 2: Final n8n image
# ─────────────────────────────────────────────────────────────
FROM docker.n8n.io/n8nio/n8n:2.6.2

USER root

# Copy binaries from tools
COPY --from=tools /toolbox/        /usr/local/bin/

# Copy ALL libs from Alpine builder
COPY --from=tools /usr/lib/        /usr/local/lib/
COPY --from=tools /lib/            /usr/local/lib2/

# Copy Python stdlib
COPY --from=tools /pylib/          /usr/lib/python-alpine/

# Copy fonts
COPY --from=tools /usr/share/fonts/      /usr/share/fonts/
COPY --from=tools /etc/fonts/            /etc/fonts/
COPY --from=tools /var/cache/fontconfig/ /var/cache/fontconfig/

# Copy SSL certs
COPY --from=tools /etc/ssl/certs/  /etc/ssl/certs/

# Environment variables
ENV LD_LIBRARY_PATH="/usr/local/lib:/usr/local/lib2:/usr/lib:$LD_LIBRARY_PATH"
ENV PATH="/usr/local/bin:$PATH"
ENV FFMPEG_PATH="/usr/local/bin/ffmpeg"
ENV FFPROBE_PATH="/usr/local/bin/ffprobe"
ENV FFREPORT="file=/tmp/ffreport-%p-%t.log:level=32"
ENV PYTHONPATH="/usr/lib/python3.12:/usr/lib/python3.12/lib-dynload"

# Setup Python symlinks and PYTHONPATH
RUN PYVER=$(cat /usr/lib/python-alpine/version.txt) && \
    echo "Setting up Python ${PYVER}" && \
    PYDIR="/usr/lib/python-alpine/python${PYVER}" && \
    ln -sf "$PYDIR" "/usr/lib/python${PYVER}" && \
    printf 'export PYTHONPATH=/usr/lib/python%s:/usr/lib/python%s/lib-dynload\n' \
      "${PYVER}" "${PYVER}" >> /etc/profile && \
    printf 'export PYTHONPATH=/usr/lib/python%s:/usr/lib/python%s/lib-dynload\n' \
      "${PYVER}" "${PYVER}" >> /root/.profile && \
    echo "Python stdlib linked at /usr/lib/python${PYVER}"

# Create runtime directories
RUN mkdir -p /tmp/ffmpeg-temp /tmp/ffmpeg-cache /var/log/ffmpeg && \
    chmod 1777 /tmp/ffmpeg-temp /tmp/ffmpeg-cache /tmp && \
    chmod 755 /var/log/ffmpeg

# Make binaries executable and verify
RUN chmod +x /usr/local/bin/ffmpeg /usr/local/bin/ffprobe && \
    /usr/local/bin/ffmpeg  -version | head -1 && \
    /usr/local/bin/ffprobe -version | head -1

# Create symlinks for ffmpeg
RUN ln -sf /usr/local/bin/ffmpeg  /usr/bin/ffmpeg  && \
    ln -sf /usr/local/bin/ffprobe /usr/bin/ffprobe && \
    ln -sf /usr/local/bin/ffmpeg  /bin/ffmpeg      && \
    ln -sf /usr/local/bin/ffprobe /bin/ffprobe

# Create symlinks for Python and bash
RUN ln -sf /usr/local/bin/python3 /usr/bin/python3 2>/dev/null || true && \
    ln -sf /usr/local/bin/python3 /usr/bin/python  2>/dev/null || true && \
    ln -sf /usr/local/bin/python3 /bin/python3     2>/dev/null || true && \
    ln -sf /usr/local/bin/python3 /bin/python      2>/dev/null || true && \
    ln -sf /usr/local/bin/bash    /bin/bash        2>/dev/null || true

# Verify Python works
RUN PYVER=$(cat /usr/lib/python-alpine/version.txt) && \
    PYTHONPATH="/usr/lib/python${PYVER}:/usr/lib/python${PYVER}/lib-dynload" \
    /usr/local/bin/python3 --version && \
    PYTHONPATH="/usr/lib/python${PYVER}:/usr/lib/python${PYVER}/lib-dynload" \
    /usr/local/bin/python3 -c "print('Python3 OK')"

# Rebuild font cache
RUN fc-cache -fv 2>/dev/null || true

# Create app directories
RUN mkdir -p /scripts /backup-data /home/node/.n8n && \
    chown -R node:node /home/node/.n8n /scripts /backup-data && \
    chown -R node:node /tmp/ffmpeg-temp /tmp/ffmpeg-cache /var/log/ffmpeg

# Install n8n community nodes as node user
USER node

RUN cd /home/node/.n8n && \
    mkdir -p nodes && \
    cd nodes && \
    npm init -y 2>/dev/null && \
    npm install @mookielianhd/n8n-nodes-instagram 2>/dev/null || true

USER root

# Copy scripts
COPY --chown=node:node scripts/ /scripts/

RUN sed -i 's/\r$//' /scripts/*.sh && \
    chmod 0755 /scripts/*.sh

# Final verification as node user
USER node

RUN ffmpeg  -version | head -1 && \
    ffprobe -version | head -1 && \
    echo "FFmpeg OK" && \
    PYVER=$(cat /usr/lib/python-alpine/version.txt) && \
    PYTHONPATH="/usr/lib/python${PYVER}:/usr/lib/python${PYVER}/lib-dynload" \
    /usr/local/bin/python3 --version && \
    PYTHONPATH="/usr/lib/python${PYVER}:/usr/lib/python${PYVER}/lib-dynload" \
    /usr/local/bin/python3 -c "t='d8a8d8b3d985d984d984d987';r=bytes.fromhex(t).decode('utf-8');print('Arabic OK:',r)" && \
    echo "aGVsbG8=" | base64 -d && echo "" && \
    fc-list :lang=ar 2>/dev/null | head -5 || echo "Arabic fonts check done" && \
    echo "===============================" && \
    echo "ALL DEPENDENCIES VERIFIED OK" && \
    echo "==============================="

WORKDIR /home/node

ENTRYPOINT ["sh", "/scripts/start.sh"]
