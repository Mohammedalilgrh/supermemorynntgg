# ─────────────────────────────────────────────────────────────
# STAGE 1: Alpine builder — install EVERYTHING here
# ─────────────────────────────────────────────────────────────
FROM alpine:3.20 AS tools

# Install all packages in builder
RUN apk add --no-cache \
      curl tar xz \
      coreutils findutils \
      bash jq \
      python3 \
      ca-certificates \
      fontconfig \
      ttf-dejavu \
      font-noto \
      font-noto-arabic \
      libass fribidi harfbuzz freetype \
      libstdc++ libgcc zlib expat

# Collect binaries
RUN mkdir -p /toolbox && \
    for cmd in \
      curl bash jq python3 \
      base64 cat grep sed awk tr \
      find xargs sort head tail \
      date sleep touch mkdir cp mv rm \
      sha256sum stat du wc cut \
      basename expr fc-cache fc-list; do \
      p="$(which $cmd 2>/dev/null)" && \
        [ -f "$p" ] && cp "$p" /toolbox/ || true; \
    done && \
    ls -la /toolbox/

# Download ffmpeg static
RUN curl -L -o /tmp/ffmpeg.tar.xz \
      https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz && \
    tar -xJf /tmp/ffmpeg.tar.xz -C /tmp/ && \
    cp /tmp/ffmpeg-*-static/ffmpeg  /toolbox/ && \
    cp /tmp/ffmpeg-*-static/ffprobe /toolbox/ && \
    rm -rf /tmp/ffmpeg-*-static /tmp/ffmpeg.tar.xz

# Debug: show exactly what Python paths exist
RUN echo "=== Python binary ===" && which python3 && python3 --version && \
    echo "=== Python lib dirs ===" && ls /usr/lib/ | grep -i python && \
    echo "=== Python3 site-packages ===" && python3 -c "import site; print(site.getsitepackages())" && \
    echo "=== Full Python prefix ===" && python3 -c "import sys; print(sys.prefix); print(sys.path)"

# Build font cache
RUN fc-cache -fv 2>/dev/null || true

# ─────────────────────────────────────────────────────────────
# STAGE 2: Final hardened n8n image
# ─────────────────────────────────────────────────────────────
FROM docker.n8n.io/n8nio/n8n:2.6.4

USER root

# Show what OS we are actually on
RUN cat /etc/os-release && echo "---" && ls /usr/lib/ | head -20

# ── Copy binaries ─────────────────────────────────────────────
COPY --from=tools /toolbox/ /usr/local/bin/

# ── Copy ALL libs from Alpine builder ────────────────────────
COPY --from=tools /usr/lib/libpython3*    /usr/lib/
COPY --from=tools /usr/lib/libfontconfig* /usr/lib/
COPY --from=tools /usr/lib/libfreetype*   /usr/lib/
COPY --from=tools /usr/lib/libharfbuzz*   /usr/lib/
COPY --from=tools /usr/lib/libfribidi*    /usr/lib/
COPY --from=tools /usr/lib/libass*        /usr/lib/
COPY --from=tools /usr/lib/libstdc++*     /usr/lib/
COPY --from=tools /usr/lib/libgcc_s*      /usr/lib/
COPY --from=tools /usr/lib/libexpat*      /usr/lib/
COPY --from=tools /usr/lib/libz*          /usr/lib/
COPY --from=tools /lib/libz*              /lib/
COPY --from=tools /lib/ld-musl*           /lib/
COPY --from=tools /lib/libc.musl*         /lib/

# ── Copy Python stdlib ───────────────────────────────────────
COPY --from=tools /usr/lib/python3.12/    /usr/lib/python3.12/
COPY --from=tools /usr/lib/python3/       /usr/lib/python3/

# ── Copy fonts ───────────────────────────────────────────────
COPY --from=tools /usr/share/fonts/       /usr/share/fonts/
COPY --from=tools /etc/fonts/             /etc/fonts/
COPY --from=tools /var/cache/fontconfig/  /var/cache/fontconfig/

# ── Copy SSL certs ───────────────────────────────────────────
COPY --from=tools /etc/ssl/certs/         /etc/ssl/certs/
COPY --from=tools /etc/ssl/cert.pem       /etc/ssl/cert.pem

# ── Environment variables ────────────────────────────────────
ENV PATH="/usr/local/bin:$PATH"
ENV LD_LIBRARY_PATH="/usr/lib:/lib:/usr/local/lib"
ENV PYTHONPATH="/usr/lib/python3.12:/usr/lib/python3.12/lib-dynload"
ENV PYTHONHOME=""
ENV FFMPEG_PATH="/usr/local/bin/ffmpeg"
ENV FFPROBE_PATH="/usr/local/bin/ffprobe"
ENV FFREPORT="file=/tmp/ffreport-%p-%t.log:level=32"

# ── Symlinks ─────────────────────────────────────────────────
RUN set -x && \
    ln -sf /usr/local/bin/python3  /usr/bin/python3   2>/dev/null || true && \
    ln -sf /usr/local/bin/python3  /usr/bin/python    2>/dev/null || true && \
    ln -sf /usr/local/bin/python3  /bin/python3       2>/dev/null || true && \
    ln -sf /usr/local/bin/python3  /bin/python        2>/dev/null || true && \
    ln -sf /usr/local/bin/ffmpeg   /usr/bin/ffmpeg    2>/dev/null || true && \
    ln -sf /usr/local/bin/ffprobe  /usr/bin/ffprobe   2>/dev/null || true && \
    ln -sf /usr/local/bin/ffmpeg   /bin/ffmpeg        2>/dev/null || true && \
    ln -sf /usr/local/bin/ffprobe  /bin/ffprobe       2>/dev/null || true && \
    ln -sf /usr/local/bin/bash     /bin/bash          2>/dev/null || true && \
    chmod +x /usr/local/bin/ffmpeg /usr/local/bin/ffprobe \
             /usr/local/bin/python3 /usr/local/bin/bash

# ── Test Python works ─────────────────────────────────────────
RUN /usr/local/bin/python3 --version && \
    /usr/local/bin/python3 -c "print('Python3 OK')" && \
    /usr/local/bin/python3 -c "t='d8a8d8b3d985';r=bytes.fromhex(t).decode('utf-8');print('Arabic:',r)"

# ── Directories ───────────────────────────────────────────────
RUN mkdir -p \
      /tmp/ffmpeg-temp /tmp/ffmpeg-cache \
      /var/log/ffmpeg /scripts \
      /backup-data /home/node/.n8n && \
    chmod 1777 /tmp/ffmpeg-temp /tmp/ffmpeg-cache /tmp && \
    chmod 755  /var/log/ffmpeg && \
    chown -R node:node \
      /home/node/.n8n /scripts /backup-data \
      /tmp/ffmpeg-temp /tmp/ffmpeg-cache /var/log/ffmpeg

# ── Community nodes ───────────────────────────────────────────
USER node

RUN cd /home/node/.n8n && \
    mkdir -p nodes && cd nodes && \
    npm init -y 2>/dev/null && \
    npm install @mookielianhd/n8n-nodes-instagram 2>/dev/null || true

USER root

COPY --chown=node:node scripts/ /scripts/

RUN find /scripts -name "*.sh" -exec sed -i 's/\r$//' {} \; && \
    chmod 0755 /scripts/*.sh

# ── Final checks ─────────────────────────────────────────────
USER node

RUN /usr/local/bin/ffmpeg  -version | head -1 && echo "ffmpeg  OK"
RUN /usr/local/bin/python3 --version           && echo "python3 OK"
RUN /usr/local/bin/python3 -c "print('stdlib OK')"
RUN echo "aGVsbG8=" | base64 -d                && echo "base64  OK"
RUN echo "BUILD COMPLETE"

WORKDIR /home/node
ENTRYPOINT ["sh", "/scripts/start.sh"]
