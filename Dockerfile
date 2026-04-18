# ============================================================
# Stage 1: toolbox (ONLY tools missing from n8n base image)
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

# IMPORTANT: Only copy tools that do NOT exist in n8n base image
# Do NOT copy: mkdir, rm, ls, cp, mv, cat, date, sleep, touch,
#              chmod, chown, stat, find, grep, sed, awk, tr,
#              cut, head, tail, sort, wc, xargs, basename, expr
# These all exist in busybox inside the n8n image already
RUN mkdir -p /toolbox && \
    for cmd in curl jq sqlite3 gzip split sha256sum; do \
      p="$(which "$cmd" 2>/dev/null)" && \
      [ -f "$p" ] && \
      cp "$p" /toolbox/ && \
      echo "✅ copied: $cmd -> $p" || \
      echo "⚠️  skip: $cmd"; \
    done && \
    echo "--- toolbox contents ---" && \
    ls -la /toolbox/

# Copy shared libraries needed by sqlite3
RUN mkdir -p /toolbox-libs && \
    for bin in /toolbox/sqlite3 /toolbox/curl /toolbox/jq; do \
      [ -f "$bin" ] && \
      ldd "$bin" 2>/dev/null | grep -o '/[^ ]*\.so[^ ]*' | while read -r lib; do \
        [ -f "$lib" ] && cp -n "$lib" /toolbox-libs/ && echo "lib: $lib" || true; \
      done || true; \
    done

# ============================================================
# Stage 2: n8n + FFmpeg
# ============================================================
FROM docker.n8n.io/n8nio/n8n:1.88.0

USER root

# ============================================================
# System packages - use n8n base apk (do NOT override system bins)
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
      jq \
      sqlite \
      ca-certificates \
      tini \
      su-exec \
      tzdata && \
    rm -rf /var/cache/apk/*

# ============================================================
# Copy ONLY the non-conflicting toolbox binaries
# sqlite3 from apk is already installed above so skip toolbox copy
# We install everything via apk - toolbox stage is now just a safety net
# ============================================================

# ============================================================
# Environment
# ============================================================
ENV PATH="/usr/bin:/bin:/usr/local/bin:/usr/sbin:/sbin:$PATH"
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
ENV EXECUTIONS_PROCESS="main"

# ============================================================
# Directories + permissions
# Use /bin/mkdir explicitly to avoid any PATH confusion
# ============================================================
RUN /bin/mkdir -p \
      /tmp/ffmpeg-temp \
      /tmp/ffmpeg-cache \
      /var/log/ffmpeg \
      /scripts \
      /backup-data \
      /home/node/.n8n \
      /home/node/.n8n/nodes \
      /usr/share/fonts/custom && \
    /bin/chmod 1777 /tmp && \
    /bin/chmod 777 /tmp/ffmpeg-temp /tmp/ffmpeg-cache && \
    /bin/chmod 755 /var/log/ffmpeg /scripts /backup-data && \
    /bin/chown -R node:node \
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
RUN /usr/bin/curl -fsSL \
      --retry 5 \
      --retry-delay 3 \
      --retry-max-time 60 \
      --connect-timeout 15 \
      -o /usr/share/fonts/custom/DejaVuSerif-Bold.ttf \
      "https://pub-4685bf7139084a5f95b995d22d06af3f.r2.dev/DejaVuSerif-Bold.ttf" \
    && /bin/chmod 644 /usr/share/fonts/custom/DejaVuSerif-Bold.ttf \
    && echo "✅ Font downloaded" \
    || echo "⚠️  Font skipped - not critical"

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
      sed -i 's/\r$//' "$f" && \
      /bin/chmod 0755 "$f" && \
      echo "✅ ready: $f"; \
    done

# ============================================================
# Build verification
# ============================================================
RUN echo "" && \
    echo "==================================" && \
    echo " BUILD VERIFICATION" && \
    echo "==================================" && \
    echo "" && \
    echo "--- System tools ---" && \
    which mkdir && mkdir --version 2>/dev/null | head -1 || true && \
    echo "" && \
    echo "--- FFmpeg ---" && \
    /usr/bin/ffmpeg -version 2>&1 | head -2 && \
    echo "" && \
    echo "--- ffprobe ---" && \
    /usr/bin/ffprobe -version 2>&1 | head -1 && \
    echo "" && \
    echo "--- drawtext ---" && \
    /usr/bin/ffmpeg -filters 2>/dev/null | grep drawtext && \
    echo "" && \
    echo "--- sqlite3 ---" && \
    /usr/bin/sqlite3 --version && \
    echo "" && \
    echo "--- curl ---" && \
    /usr/bin/curl --version | head -1 && \
    echo "" && \
    echo "--- jq ---" && \
    /usr/bin/jq --version && \
    echo "" && \
    echo "--- fonts ---" && \
    fc-list | grep -i "noto\|dejavu" | head -5 && \
    echo "" && \
    echo "--- all required tools ---" && \
    for t in ffmpeg ffprobe sqlite3 curl jq bash tini su-exec; do \
      which "$t" > /dev/null 2>&1 \
        && echo "  ✅ $t -> $(which $t)" \
        || echo "  ❌ $t MISSING"; \
    done && \
    echo "" && \
    echo "--- scripts ---" && \
    ls -la /scripts/ && \
    echo "" && \
    echo "==================================" && \
    echo " ✅ ALL CHECKS PASSED" && \
    echo "==================================="

# ============================================================
# Runtime
# ============================================================
USER node
WORKDIR /home/node
EXPOSE 5678

ENTRYPOINT ["/sbin/tini", "--", "sh", "/scripts/start.sh"]
