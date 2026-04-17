# ============================================================
# Stage 1: toolbox (small useful binaries)
# ============================================================
FROM alpine:3.19 AS tools

RUN apk add --no-cache \
      curl \
      jq \
      sqlite \
      tar \
      gzip \
      xz \
      coreutils \
      findutils \
      bash \
      ca-certificates

RUN mkdir -p /toolbox && \
    for cmd in \
      curl jq sqlite3 split sha256sum \
      stat du sort tail awk xargs find \
      wc cut tr gzip tar cat date sleep \
      mkdir rm ls grep sed head touch \
      cp mv basename expr bash sh; \
    do \
      p="$(which "$cmd" 2>/dev/null)" && \
      [ -f "$p" ] && \
      cp "$p" /toolbox/ && \
      echo "✅ $cmd" || \
      echo "⚠️  skip: $cmd"; \
    done && \
    ls -la /toolbox/

# ============================================================
# Stage 2: n8n + FFmpeg
# ============================================================
FROM docker.n8n.io/n8nio/n8n:2.6.2

USER root

# ============================================================
# System packages
# ============================================================
RUN apk update && \
    apk add --no-cache \
      ffmpeg \
      fontconfig \
      ttf-dejavu \
      font-noto \
      font-noto-arabic \
      libass \
      freetype \
      harfbuzz \
      fribidi \
      bash \
      curl \
      ca-certificates \
      shadow && \
    rm -rf /var/cache/apk/*

# ============================================================
# Copy toolbox
# ============================================================
COPY --from=tools /toolbox/ /usr/local/bin/
RUN chmod -R 755 /usr/local/bin/

# ============================================================
# Environment
# ============================================================
ENV PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
ENV FFMPEG_PATH="/usr/bin/ffmpeg"
ENV FFPROBE_PATH="/usr/bin/ffprobe"
ENV FFREPORT="file=/tmp/ffreport-%p-%t.log:level=32"
ENV N8N_USER_FOLDER="/home/node/.n8n"
ENV N8N_CUSTOM_EXTENSIONS="/home/node/.n8n/nodes"
ENV NODE_FUNCTION_ALLOW_EXTERNAL="*"
ENV NODE_OPTIONS="--max-old-space-size=4096"
ENV GENERIC_TIMEZONE="UTC"
ENV TZ="UTC"

# ============================================================
# Directories + permissions
# ============================================================
RUN mkdir -p \
      /tmp/ffmpeg-temp \
      /tmp/ffmpeg-cache \
      /var/log/ffmpeg \
      /scripts \
      /backup-data \
      /home/node/.n8n \
      /home/node/.n8n/nodes \
      /usr/share/fonts/custom && \
    chmod 1777 /tmp && \
    chmod 777 /tmp/ffmpeg-temp /tmp/ffmpeg-cache && \
    chmod 755 /var/log/ffmpeg /scripts /backup-data && \
    chown -R node:node \
      /home/node/.n8n \
      /scripts \
      /backup-data \
      /tmp/ffmpeg-temp \
      /tmp/ffmpeg-cache \
      /var/log/ffmpeg

# ============================================================
# Custom font download
# ============================================================
RUN curl -fsSL \
      --retry 5 \
      --retry-delay 3 \
      --retry-max-time 60 \
      --connect-timeout 15 \
      -o /usr/share/fonts/custom/DejaVuSerif-Bold.ttf \
      "https://pub-4685bf7139084a5f95b995d22d06af3f.r2.dev/DejaVuSerif-Bold.ttf" \
    && chmod 644 /usr/share/fonts/custom/DejaVuSerif-Bold.ttf \
    && echo "✅ Custom font OK" \
    || echo "⚠️  Custom font skipped"

# Rebuild font cache
RUN fc-cache -fv && \
    echo "✅ Font cache OK"

# ============================================================
# Custom n8n nodes (as node user)
# ============================================================
USER node

RUN cd /home/node/.n8n/nodes && \
    npm init -y > /dev/null 2>&1 && \
    npm install --save \
      @mookielianhd/n8n-nodes-instagram \
    > /dev/null 2>&1 \
    && echo "✅ Custom nodes installed" \
    || echo "⚠️  Custom nodes skipped"

USER root

# ============================================================
# Copy + prepare scripts
# ============================================================
COPY --chown=node:node scripts/ /scripts/

RUN find /scripts -name "*.sh" -exec sed -i 's/\r$//' {} \; && \
    find /scripts -name "*.sh" -exec chmod 0755 {} \; && \
    echo "✅ Scripts prepared"

# ============================================================
# Final verification (build-time check)
# ============================================================
RUN echo "=== FFmpeg ===" && \
    ffmpeg -version 2>&1 | head -2 && \
    echo "" && \
    echo "=== drawtext ===" && \
    ffmpeg -filters 2>/dev/null | grep drawtext && \
    echo "" && \
    echo "=== ffprobe ===" && \
    ffprobe -version 2>&1 | head -2 && \
    echo "" && \
    echo "=== Fonts ===" && \
    fc-list | grep -i "noto\|dejavu" | head -10 && \
    echo "" && \
    echo "=== Tools ===" && \
    for t in curl jq bash ffmpeg ffprobe; do \
      which "$t" > /dev/null 2>&1 \
        && echo "  ✅ $t: $(which $t)" \
        || echo "  ❌ $t: MISSING"; \
    done && \
    echo "" && \
    echo "=== n8n nodes ===" && \
    ls /home/node/.n8n/nodes/node_modules/ 2>/dev/null | head -10 || true && \
    echo "" && \
    echo "✅ ALL CHECKS PASSED"

# ============================================================
# Switch to node user for runtime
# ============================================================
USER node

WORKDIR /home/node

EXPOSE 5678

ENTRYPOINT ["sh", "/scripts/start.sh"]
