# ============================================================
# Stage 1: toolbox (small useful binaries)
# ============================================================
FROM alpine:3.20 AS tools

RUN apk add --no-cache \
      curl jq sqlite tar gzip xz \
      coreutils findutils ca-certificates

RUN mkdir -p /toolbox && \
    for cmd in curl jq sqlite3 split sha256sum \
               stat du sort tail awk xargs find \
               wc cut tr gzip tar cat date sleep \
               mkdir rm ls grep sed head touch \
               cp mv basename expr; do \
      p="$(which $cmd 2>/dev/null)" && \
      [ -f "$p" ] && cp "$p" /toolbox/ || true; \
    done

# ============================================================
# Stage 2: n8n + FFmpeg (CLEAN SETUP)
# ============================================================
FROM docker.n8n.io/n8nio/n8n:2.6.2

USER root

# ✅ Install REAL ffmpeg (NOT static)
RUN apk add --no-cache \
    ffmpeg \
    fontconfig \
    ttf-dejavu \
    font-noto \
    font-noto-arabic \
    libass \
    freetype \
    harfbuzz \
    fribidi

# ✅ Copy toolbox only (safe)
COPY --from=tools /toolbox/ /usr/local/bin/

ENV PATH="/usr/local/bin:$PATH"

# ============================================================
# FFmpeg environment
# ============================================================
ENV FFMPEG_PATH="/usr/bin/ffmpeg"
ENV FFPROBE_PATH="/usr/bin/ffprobe"
ENV FFREPORT="file=/tmp/ffreport-%p-%t.log:level=32"

# ============================================================
# Temp + permissions
# ============================================================
RUN mkdir -p /tmp/ffmpeg-temp /tmp/ffmpeg-cache /var/log/ffmpeg && \
    chmod 1777 /tmp /tmp/ffmpeg-temp /tmp/ffmpeg-cache && \
    chmod 755 /var/log/ffmpeg

# ============================================================
# Fonts (custom optional)
# ============================================================
RUN mkdir -p /usr/share/fonts/custom && \
    curl -L -o /usr/share/fonts/custom/DejaVuSerif-Bold.ttf \
    https://pub-4685bf7139084a5f95b995d22d06af3f.r2.dev/DejaVuSerif-Bold.ttf && \
    chmod 644 /usr/share/fonts/custom/DejaVuSerif-Bold.ttf

RUN fc-cache -fv

# ============================================================
# n8n setup
# ============================================================
RUN mkdir -p /scripts /backup-data /home/node/.n8n && \
    chown -R node:node /home/node/.n8n /scripts /backup-data

RUN chown -R node:node /tmp /tmp/ffmpeg-temp /tmp/ffmpeg-cache /var/log/ffmpeg

USER node

# optional nodes
RUN cd /home/node/.n8n && \
    mkdir -p nodes && \
    cd nodes && \
    npm init -y >/dev/null 2>&1 && \
    npm install @mookielianhd/n8n-nodes-instagram >/dev/null 2>&1 || true

USER root

COPY --chown=node:node scripts/ /scripts/

RUN sed -i 's/\r$//' /scripts/*.sh && \
    chmod 0755 /scripts/*.sh

# ============================================================
# FINAL CHECK (IMPORTANT)
# ============================================================
USER node

RUN ffmpeg -version && \
    ffmpeg -filters | grep drawtext && \
    fc-list | grep -i noto | head -5 && \
    echo "✅ FFmpeg + drawtext + fonts OK"

WORKDIR /home/node

ENTRYPOINT ["sh", "/scripts/start.sh"]
