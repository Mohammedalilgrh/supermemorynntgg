# ============================================================
# Stage 1: Tools + FFmpeg static build
# ============================================================
FROM alpine:3.20 AS tools

RUN apk add --no-cache \
    curl jq sqlite tar gzip xz \
    coreutils findutils ca-certificates

RUN mkdir -p /toolbox

# Copy common CLI tools
RUN for cmd in curl jq sqlite3 split sha256sum \
               stat du sort tail awk xargs find \
               wc cut tr gzip tar cat date sleep \
               mkdir rm ls grep sed head touch \
               cp mv basename expr; do \
      p="$(which $cmd 2>/dev/null)" && \
      [ -f "$p" ] && cp "$p" /toolbox/ || true; \
    done

# Download static FFmpeg
RUN curl -L -o /tmp/ffmpeg.tar.xz \
    https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz && \
    tar -xJf /tmp/ffmpeg.tar.xz -C /tmp/ && \
    cp /tmp/ffmpeg-*-static/ffmpeg /toolbox/ && \
    cp /tmp/ffmpeg-*-static/ffprobe /toolbox/ && \
    chmod +x /toolbox/ffmpeg /toolbox/ffprobe && \
    rm -rf /tmp/*


# ============================================================
# Stage 2: n8n runtime (FIXED)
# ============================================================
FROM docker.n8n.io/n8nio/n8n:2.6.2

USER root

# Copy tools ONLY (NO system libs from Alpine!)
COPY --from=tools /toolbox/ /usr/local/bin/

# Certificates
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    fontconfig \
    fonts-dejavu \
    fonts-noto \
    fonts-noto-core \
    fonts-noto-extra \
    libass9 \
    fribidi \
    libharfbuzz0b \
    libfreetype6 \
    libstdc++6 \
    && rm -rf /var/lib/apt/lists/*

# Font directory
RUN mkdir -p /usr/local/share/fonts/custom

# Download custom font
RUN curl -L -o /usr/local/share/fonts/custom/DejaVuSerif-Bold.ttf \
    https://pub-4685bf7139084a5f95b995d22d06af3f.r2.dev/DejaVuSerif-Bold.ttf && \
    chmod 644 /usr/local/share/fonts/custom/DejaVuSerif-Bold.ttf && \
    fc-cache -fv

# Env
ENV FFMPEG_PATH="/usr/local/bin/ffmpeg"
ENV FFPROBE_PATH="/usr/local/bin/ffprobe"
ENV FFMPEG_FONTS="/usr/local/share/fonts/custom"

# Temp folders
RUN mkdir -p /tmp/ffmpeg-temp /tmp/ffmpeg-cache /var/log/ffmpeg && \
    chmod 1777 /tmp/ffmpeg-temp /tmp/ffmpeg-cache /tmp /var/log/ffmpeg

# Symlinks safety
RUN ln -sf /usr/local/bin/ffmpeg /usr/bin/ffmpeg && \
    ln -sf /usr/local/bin/ffprobe /usr/bin/ffprobe

# n8n folders
RUN mkdir -p /scripts /backup-data /home/node/.n8n && \
    chown -R node:node /home/node/.n8n /scripts /backup-data

# scripts
COPY --chown=node:node scripts/ /scripts/
RUN sed -i 's/\r$//' /scripts/*.sh && \
    chmod +x /scripts/*.sh

# install community node (safe)
USER node
RUN cd /home/node/.n8n && \
    mkdir -p nodes && \
    cd nodes && \
    npm init -y && \
    npm install @mookielianhd/n8n-nodes-instagram || true

# final
USER root

RUN ffmpeg -version && ffprobe -version && fc-list | head -n 5

WORKDIR /home/node

ENTRYPOINT ["sh", "/scripts/start.sh"]
