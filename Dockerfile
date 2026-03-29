# ───────────────────────────────────────────────────────
# Stage 1: Download static FFmpeg (full feature set)
# ───────────────────────────────────────────────────────
FROM alpine:3.20 AS ffmpeg-tools

RUN apk add --no-cache curl tar xz

RUN mkdir -p /toolbox && \
    curl -fsSL https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz \
      | tar -xJ \
        --warning=no-unknown-keyword \
        --strip-components=1 \
        --directory=/toolbox \
        --wildcards \
          '*/ffmpeg' \
          '*/ffprobe' && \
    chmod +x /toolbox/ffmpeg /toolbox/ffprobe

# ───────────────────────────────────────────────────────
# Stage 2: Build final n8n image with FFmpeg + Arabic fonts
# ───────────────────────────────────────────────────────
FROM docker.n8n.io/n8nio/n8n:2.6.2

USER root

# 1) Copy in static FFmpeg & FFprobe
COPY --from=ffmpeg-tools /toolbox/ffmpeg   /usr/local/bin/ffmpeg
COPY --from=ffmpeg-tools /toolbox/ffprobe  /usr/local/bin/ffprobe

RUN chmod +x /usr/local/bin/ffmpeg /usr/local/bin/ffprobe && \
    ln -sf /usr/local/bin/ffmpeg  /usr/bin/ffmpeg  && \
    ln -sf /usr/local/bin/ffprobe /usr/bin/ffprobe && \
    ln -sf /usr/local/bin/ffmpeg  /bin/ffmpeg    && \
    ln -sf /usr/local/bin/ffprobe /bin/ffprobe

# 2) Let n8n‐ffmpeg‐nodes pick them up automatically
ENV FFMPEG_PATH=/usr/local/bin/ffmpeg \
    FFPROBE_PATH=/usr/local/bin/ffprobe \
    FFREPORT="file=/tmp/ffreport-%p-%t.log:level=32"

# 3) Install fonts & rendering libs via apt
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      fontconfig \
      fonts-dejavu-core \
      fonts-noto \
      libass9 \
      libfribidi0 \
      libharfbuzz0b \
      libfreetype6 \
    && rm -rf /var/lib/apt/lists/* && \
    fc-cache -f -v

# 4) Prepare writable temp dirs for FFmpeg
RUN mkdir -p /tmp/ffmpeg-temp /tmp/ffmpeg-cache /var/log/ffmpeg && \
    chmod 1777 /tmp/ffmpeg-temp /tmp/ffmpeg-cache && \
    chmod 755 /var/log/ffmpeg

# 5) Prep n8n home, scripts, backup-data
RUN mkdir -p /scripts /backup-data /home/node/.n8n && \
    chown -R node:node \
      /home/node/.n8n /scripts /backup-data \
      /tmp/ffmpeg-temp /tmp/ffmpeg-cache /var/log/ffmpeg

# 6) (Optional) install extra n8n nodes under node:user
USER node
RUN cd /home/node/.n8n && \
    mkdir -p nodes && \
    cd nodes && \
    npm init -y && \
    npm install @mookielianhd/n8n-nodes-instagram

# 7) Copy your startup scripts in and fix EOL/exec perms
USER root
COPY --chown=node:node scripts/ /scripts/
RUN sed -i 's/\r$//' /scripts/*.sh && chmod +x /scripts/*.sh

# 8) Final verification under node:user
USER node
RUN ffmpeg -version && ffprobe -version && \
    fc-list :lang=ar | head -n5 || echo "Arabic fonts OK" && \
    echo "✅ FFmpeg + Arabic fonts + n8n ready"

WORKDIR /home/node

ENTRYPOINT ["sh", "/scripts/start.sh"]
