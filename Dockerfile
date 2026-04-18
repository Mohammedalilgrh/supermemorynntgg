# ============================================================
# Stage 1: toolbox
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
    done

# ============================================================
# Stage 2: n8n + FFmpeg
# ============================================================
FROM docker.n8n.io/n8nio/n8n:1.88.0

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
      sqlite \
      tini \
      su-exec \
      tzdata && \
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
ENV NODE_OPTIONS="--max-old-space-size=512"
ENV GENERIC_TIMEZONE="Asia/Baghdad"
ENV TZ="Asia/Baghdad"
ENV N8N_HOST="0.0.0.0"
ENV N8N_PORT="5678"
ENV N8N_PROTOCOL="https"
ENV N8N_SECURE_COOKIE="false"
ENV N8N_DIAGNOSTICS_ENABLED="false"
ENV N8N_VERSION_NOTIFICATIONS_ENABLED="false"
ENV DB_TYPE="sqlite"
ENV DB_SQLITE_DATABASE="/home/node/.n8n/database.sqlite"
ENV N8N_DEFAULT_BINARY_DATA_MODE="filesystem"
ENV N8N_BINARY_DATA_TTL="1"
ENV EXECUTIONS_DATA_PRUNE="true"
ENV EXECUTIONS_DATA_MAX_AGE="10"
ENV EXECUTIONS_DATA_SAVE_ON_SUCCESS="none"
ENV EXECUTIONS_DATA_SAVE_ON_ERROR="none"
ENV EXECUTIONS_DATA_SAVE_MANUAL_EXECUTIONS="false"

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
      /var/log/ffmpeg \
      /usr/share/fonts/custom

# ============================================================
# Custom font
# ============================================================
RUN curl -fsSL \
      --retry 5 \
      --retry-delay 3 \
      --retry-max-time 60 \
      --connect-timeout 15 \
      -o /usr/share/fonts/custom/DejaVuSerif-Bold.ttf \
      "https://pub-4685bf7139084a5f95b995d22d06af3f.r2.dev/DejaVuSerif-Bold.ttf" \
    && chmod 644 /usr/share/fonts/custom/DejaVuSerif-Bold.ttf \
    && echo "✅ Font downloaded" \
    || echo "⚠️  Font skipped"

RUN fc-cache -fv && echo "✅ Font cache OK"

# ============================================================
# Custom n8n nodes (as node user)
# ============================================================
USER node

RUN cd /home/node/.n8n/nodes && \
    npm init -y > /dev/null 2>&1 && \
    npm install \
      --save \
      --no-audit \
      --no-fund \
      @mookielianhd/n8n-nodes-instagram \
    > /dev/null 2>&1 \
    && echo "✅ Custom nodes OK" \
    || echo "⚠️  Custom nodes skipped"

USER root

# ============================================================
# Copy scripts
# ============================================================
COPY --chown=node:node scripts/ /scripts/

RUN find /scripts -name "*.sh" | while read -r f; do \
      sed -i 's/\r$//' "$f"; \
      chmod 0755 "$f"; \
      echo "✅ $f ready"; \
    done

# ============================================================
# Build verification
# ============================================================
RUN echo "=== FFmpeg ===" && \
    ffmpeg -version 2>&1 | head -2 && \
    echo "=== drawtext ===" && \
    ffmpeg -filters 2>/dev/null | grep drawtext && \
    echo "=== ffprobe ===" && \
    ffprobe -version 2>&1 | head -1 && \
    echo "=== sqlite3 ===" && \
    sqlite3 --version && \
    echo "=== fonts ===" && \
    fc-list | grep -i "noto\|dejavu" | head -5 && \
    echo "=== tools ===" && \
    for t in curl jq bash ffmpeg ffprobe sqlite3 tini su-exec; do \
      which "$t" > /dev/null 2>&1 \
        && echo "  ✅ $t" \
        || echo "  ❌ $t MISSING"; \
    done && \
    echo "=== scripts ===" && \
    ls -la /scripts/ && \
    echo "✅ BUILD OK"

# ============================================================
# Runtime
# ============================================================
USER node
WORKDIR /home/node
EXPOSE 5678

ENTRYPOINT ["/sbin/tini", "--", "sh", "/scripts/start.sh"]
