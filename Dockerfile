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
      ca-certificates \
      bash

RUN mkdir -p /toolbox && \
    for cmd in \
      curl jq sqlite3 split sha256sum \
      stat du sort tail awk xargs find \
      wc cut tr gzip tar cat date sleep \
      mkdir rm ls grep sed head touch \
      cp mv basename expr bash sh; \
    do \
      p="$(which "$cmd" 2>/dev/null)" && \
      [ -f "$p" ] && cp "$p" /toolbox/ && echo "Copied: $cmd ($p)" || echo "Skip: $cmd"; \
    done

# ============================================================
# Stage 2: n8n + FFmpeg
# ============================================================
FROM docker.n8n.io/n8nio/n8n:2.6.2

USER root

# ✅ Fix apk repositories and install ffmpeg + fonts
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
      ca-certificates && \
    rm -rf /var/cache/apk/*

# ✅ Copy toolbox binaries safely
COPY --from=tools /toolbox/ /usr/local/bin/

# ✅ Ensure correct permissions on toolbox
RUN chmod 755 /usr/local/bin/*

# ============================================================
# PATH + FFmpeg environment
# ============================================================
ENV PATH="/usr/local/bin:/usr/bin:/bin:$PATH"
ENV FFMPEG_PATH="/usr/bin/ffmpeg"
ENV FFPROBE_PATH="/usr/bin/ffprobe"
ENV FFREPORT="file=/tmp/ffreport-%p-%t.log:level=32"

# ============================================================
# n8n specific environment
# ============================================================
ENV N8N_USER_FOLDER="/home/node/.n8n"
ENV NODE_FUNCTION_ALLOW_EXTERNAL="*"
ENV N8N_CUSTOM_EXTENSIONS="/home/node/.n8n/nodes"

# ============================================================
# Temp directories + permissions
# ============================================================
RUN mkdir -p \
      /tmp/ffmpeg-temp \
      /tmp/ffmpeg-cache \
      /var/log/ffmpeg && \
    chmod 1777 /tmp && \
    chmod 777 /tmp/ffmpeg-temp /tmp/ffmpeg-cache && \
    chmod 755 /var/log/ffmpeg

# ============================================================
# Fonts (custom + system rebuild)
# ============================================================
RUN mkdir -p /usr/share/fonts/custom

# Download custom font with retry + fallback
RUN curl -fsSL \
      --retry 3 \
      --retry-delay 2 \
      --connect-timeout 10 \
      -o /usr/share/fonts/custom/DejaVuSerif-Bold.ttf \
      "https://pub-4685bf7139084a5f95b995d22d06af3f.r2.dev/DejaVuSerif-Bold.ttf" && \
    chmod 644 /usr/share/fonts/custom/DejaVuSerif-Bold.ttf && \
    echo "✅ Custom font downloaded" || \
    echo "⚠️  Custom font download failed - continuing without it"

RUN fc-cache -fv && \
    fc-list | head -10 && \
    echo "✅ Font cache rebuilt"

# ============================================================
# n8n directories + custom nodes
# ============================================================
RUN mkdir -p \
      /scripts \
      /backup-data \
      /home/node/.n8n \
      /home/node/.n8n/nodes && \
    chown -R node:node \
      /home/node/.n8n \
      /scripts \
      /backup-data && \
    chown node:node \
      /tmp/ffmpeg-temp \
      /tmp/ffmpeg-cache \
      /var/log/ffmpeg

# ============================================================
# Install custom n8n nodes
# ============================================================
USER node

# Initialize npm and install custom node packages
RUN cd /home/node/.n8n/nodes && \
    npm init -y && \
    npm install \
      --save \
      --prefer-offline \
      @mookielianhd/n8n-nodes-instagram \
    2>&1 | tail -5 || \
    echo "⚠️  Custom node install failed - continuing"

USER root

# ============================================================
# Copy scripts
# ============================================================
COPY --chown=node:node scripts/ /scripts/

# Fix Windows line endings + set executable
RUN if ls /scripts/*.sh >/dev/null 2>&1; then \
      sed -i 's/\r$//' /scripts/*.sh && \
      chmod 0755 /scripts/*.sh && \
      echo "✅ Scripts prepared"; \
    else \
      echo "⚠️  No .sh scripts found in /scripts/"; \
    fi

# ============================================================
# Verify everything works
# ============================================================
USER node

RUN echo "=== FFmpeg Version ===" && \
    ffmpeg -version 2>&1 | head -3 && \
    echo "" && \
    echo "=== drawtext filter check ===" && \
    ffmpeg -filters 2>/dev/null | grep drawtext && \
    echo "" && \
    echo "=== Noto fonts ===" && \
    fc-list 2>/dev/null | grep -i noto | head -5 || echo "No noto fonts found" && \
    echo "" && \
    echo "=== DejaVu fonts ===" && \
    fc-list 2>/dev/null | grep -i dejavu | head -5 || echo "No dejavu fonts found" && \
    echo "" && \
    echo "=== Tool availability ===" && \
    for tool in curl jq ffmpeg ffprobe; do \
      which "$tool" && echo "  ✅ $tool OK" || echo "  ❌ $tool MISSING"; \
    done && \
    echo "" && \
    echo "✅ All checks complete"

# ============================================================
# Final setup
# ============================================================
WORKDIR /home/node

EXPOSE 5678

ENTRYPOINT ["sh", "/scripts/start.sh"]
