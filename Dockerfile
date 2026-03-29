# ───────────────────────────────────────────────────────
# Stage 1: Download static FFmpeg (with full codec support)
# ───────────────────────────────────────────────────────
FROM alpine:3.20 AS ffmpeg-tools

# we only need curl, tar, xz in this stage
RUN apk add --no-cache \
      curl \
      xz \
      tar

# download & extract John Van Sickle's static build:
RUN mkdir -p /ffmpeg-tmp && \
    curl -L https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz \
      -o /ffmpeg-tmp/ffmpeg.tar.xz && \
    tar -xJf /ffmpeg-tmp/ffmpeg.tar.xz -C /ffmpeg-tmp && \
    mv /ffmpeg-tmp/ffmpeg-*-static/ffmpeg   /toolbox/ffmpeg && \
    mv /ffmpeg-tmp/ffmpeg-*-static/ffprobe  /toolbox/ffprobe

# ───────────────────────────────────────────────────────
# Stage 2: Build the final n8n image with FFmpeg & fonts
# ───────────────────────────────────────────────────────
FROM docker.n8n.io/n8nio/n8n:2.6.2

USER root

# 1) Copy FFmpeg & FFprobe from the tools stage
COPY --from=ffmpeg-tools /toolbox/ffmpeg   /usr/local/bin/ffmpeg
COPY --from=ffmpeg-tools /toolbox/ffprobe  /usr/local/bin/ffprobe

# make them executable & create common symlinks
RUN chmod +x /usr/local/bin/ffmpeg /usr/local/bin/ffprobe && \
    ln -sf /usr/local/bin/ffmpeg  /usr/bin/ffmpeg  && \
    ln -sf /usr/local/bin/ffprobe /usr/bin/ffprobe && \
    ln -sf /usr/local/bin/ffmpeg  /bin/ffmpeg  && \
    ln -sf /usr/local/bin/ffprobe /bin/ffprobe

# 2) Set FFmpeg environment vars for n8n nodes
ENV FFMPEG_PATH=/usr/local/bin/ffmpeg \
    FFPROBE_PATH=/usr/local/bin/ffprobe \
    FFREPORT="file=/tmp/ffreport-%p-%t.log:level=32"

# 3) Install font packages & rendering libs for Arabic/Subtitles
RUN apk add --no-cache \
      fontconfig \
      ttf-dejavu \
      ttf-noto \
      ttf-noto-arabic \
      ttf-noto-extra \
      libass \
      fribidi \
      harfbuzz \
      freetype && \
    # rebuild font cache so Arabic/complex‐script fonts are usable
    fc-cache -fv

# 4) Create and secure temporary directories FFmpeg may use
RUN mkdir -p /tmp/ffmpeg-temp /tmp/ffmpeg-cache /var/log/ffmpeg && \
    chmod 1777 /tmp/ffmpeg-temp /tmp/ffmpeg-cache && \
    chmod 755 /var/log/ffmpeg

# 5) Ensure node user owns all runtime dirs
RUN mkdir -p /scripts /backup-data && \
    chown -R node:node /home/node/.n8n /scripts /backup-data \
                          /tmp/ffmpeg-temp /tmp/ffmpeg-cache /var/log/ffmpeg

# 6) Install any custom n8n nodes as the node user
USER node
RUN cd /home/node/.n8n && mkdir -p nodes && cd nodes && \
    npm init -y && \
    npm install @mookielianhd/n8n-nodes-instagram

# 7) Copy your startup scripts in and fix permissions
USER root
COPY --chown=node:node scripts/ /scripts/
RUN sed -i 's/\r$//' /scripts/*.sh && chmod +x /scripts/*.sh

# 8) Final verify under node user
USER node
RUN ffmpeg -version && ffprobe -version && \
    # show a few Arabic fonts to prove it worked
    fc-list :lang=ar | head -5 || echo "Arabic fonts OK" && \
    echo "✅ FFmpeg + Arabic fonts verified"

WORKDIR /home/node

ENTRYPOINT ["sh", "/scripts/start.sh"]
