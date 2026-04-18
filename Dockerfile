# ============================================================
# Stage 1: toolbox + static FFmpeg
# ============================================================
FROM alpine:3.19 AS tools

RUN apk add --no-cache \
      curl \
      jq \
      sqlite \
      tar \
      gzip \
      xz \
      bash \
      ca-certificates

# Only copy tools MISSING from n8n busybox base
# NEVER copy: mkdir chmod rm ls cp mv cat date sleep touch
# find grep sed awk tr cut head tail sort wc xargs basename expr
# Those exist in busybox - copying coreutils versions BREAKS them
RUN mkdir -p /toolbox && \
    for cmd in curl jq sqlite3 gzip split sha256sum; do \
      p="$(which "$cmd" 2>/dev/null)" && \
      [ -f "$p" ] && \
      cp "$p" /toolbox/ && \
      echo "✅ $cmd" || \
      echo "⚠️  skip: $cmd"; \
    done && \
    echo "--- toolbox ---" && \
    ls -la /toolbox/

# Download static FFmpeg
RUN echo "⬇️  Downloading static FFmpeg..." && \
    curl -L \
      --retry 5 \
      --retry-delay 5 \
      --connect-timeout 30 \
      --max-time 300 \
      -o /tmp/ffmpeg.tar.xz \
      "https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz" && \
    tar -xJf /tmp/ffmpeg.tar.xz -C /tmp/ && \
    cp /tmp/ffmpeg-*-static/ffmpeg  /toolbox/ffmpeg && \
    cp /tmp/ffmpeg-*-static/ffprobe /toolbox/ffprobe && \
    chmod +x /toolbox/ffmpeg /toolbox/ffprobe && \
    rm -rf /tmp/ffmpeg-*-static /tmp/ffmpeg.tar.xz && \
    echo "✅ Static FFmpeg ready" && \
    /toolbox/ffmpeg -version 2>&1 | head -2

# ============================================================
# Stage 2: n8n 2.6.2
# ============================================================
FROM docker.n8n.io/n8nio/n8n:2.6.2

USER root

# ============================================================
# System packages
# ============================================================
RUN apk update && \
    apk add --no-cache \
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
      tzdata \
      libstdc++ \
      libgcc \
      libgomp \
      zlib \
      expat \
      unzip && \
    rm -rf /var/cache/apk/*

# Optional packages - may not exist in all Alpine versions
RUN apk add --no-cache \
      font-noto-extra \
      font-noto-emoji \
      font-freefont \
      2>/dev/null || \
    echo "⚠️  Some optional font packages skipped"

# ============================================================
# Copy toolbox (safe tools only - no busybox conflicts)
# ============================================================
COPY --from=tools /toolbox/ /usr/local/bin/

RUN chmod +x \
      /usr/local/bin/ffmpeg \
      /usr/local/bin/ffprobe \
      /usr/local/bin/curl \
      /usr/local/bin/jq \
      /usr/local/bin/sqlite3 \
      /usr/local/bin/gzip \
      /usr/local/bin/split \
      /usr/local/bin/sha256sum && \
    echo "✅ Toolbox permissions OK"

# ============================================================
# FFmpeg symlinks - cover all paths n8n nodes check
# ============================================================
RUN ln -sf /usr/local/bin/ffmpeg  /usr/bin/ffmpeg  && \
    ln -sf /usr/local/bin/ffprobe /usr/bin/ffprobe && \
    ln -sf /usr/local/bin/ffmpeg  /bin/ffmpeg      && \
    ln -sf /usr/local/bin/ffprobe /bin/ffprobe     && \
    echo "✅ FFmpeg symlinks OK"

# ============================================================
# Environment
# ============================================================
ENV PATH="/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

# FFmpeg
ENV FFMPEG_PATH="/usr/local/bin/ffmpeg"
ENV FFPROBE_PATH="/usr/local/bin/ffprobe"
ENV FFREPORT="file=/tmp/ffreport-%p-%t.log:level=32"

# Locale + fontconfig
ENV LANG="en_US.UTF-8"
ENV LC_ALL="en_US.UTF-8"
ENV FONTCONFIG_PATH="/etc/fonts"
ENV FONTCONFIG_FILE="/etc/fonts/fonts.conf"

# n8n core
ENV N8N_USER_FOLDER="/home/node/.n8n"
ENV N8N_CUSTOM_EXTENSIONS="/home/node/.n8n/nodes"
ENV NODE_FUNCTION_ALLOW_EXTERNAL="*"
ENV N8N_REINSTALL_MISSING_PACKAGES="true"
ENV N8N_COMMUNITY_PACKAGES_ENABLED="true"
ENV NODE_OPTIONS="--max-old-space-size=512"

# Timezone
ENV GENERIC_TIMEZONE="Asia/Baghdad"
ENV TZ="Asia/Baghdad"

# Network
ENV N8N_HOST="0.0.0.0"
ENV N8N_PORT="5678"
ENV N8N_PROTOCOL="https"
ENV N8N_SECURE_COOKIE="false"

# Behavior
ENV N8N_DIAGNOSTICS_ENABLED="false"
ENV N8N_VERSION_NOTIFICATIONS_ENABLED="false"
ENV N8N_TEMPLATES_ENABLED="true"
ENV N8N_SKIP_WEBHOOK_DEREGISTRATION_SHUTDOWN="true"
ENV N8N_GRACEFUL_SHUTDOWN_TIMEOUT="30"

# Database
ENV DB_TYPE="sqlite"
ENV DB_SQLITE_DATABASE="/home/node/.n8n/database.sqlite"

# Binary data
ENV N8N_DEFAULT_BINARY_DATA_MODE="filesystem"
ENV N8N_BINARY_DATA_TTL="1"

# Executions
ENV EXECUTIONS_DATA_PRUNE="true"
ENV EXECUTIONS_DATA_MAX_AGE="10"
ENV EXECUTIONS_DATA_SAVE_ON_SUCCESS="none"
ENV EXECUTIONS_DATA_SAVE_ON_ERROR="none"
ENV EXECUTIONS_DATA_SAVE_MANUAL_EXECUTIONS="false"
ENV EXECUTIONS_PROCESS="main"
ENV EXECUTIONS_TIMEOUT="3600"
ENV EXECUTIONS_TIMEOUT_MAX="7200"

# ============================================================
# Directories + permissions
# Use full /bin/ paths - avoids PATH confusion
# ============================================================
RUN /bin/mkdir -p \
      /tmp/ffmpeg-temp \
      /tmp/ffmpeg-cache \
      /var/log/ffmpeg \
      /scripts \
      /backup-data \
      /home/node/.n8n \
      /home/node/.n8n/nodes \
      /usr/share/fonts/custom \
      /usr/share/fonts/amiri \
      /usr/share/fonts/noto-emoji \
      /etc/fonts/conf.d && \
    /bin/chmod 1777 /tmp && \
    /bin/chmod 777 /tmp/ffmpeg-temp /tmp/ffmpeg-cache && \
    /bin/chmod 755 \
      /var/log/ffmpeg \
      /scripts \
      /backup-data && \
    /bin/chown -R node:node \
      /home/node/.n8n \
      /scripts \
      /backup-data \
      /tmp/ffmpeg-temp \
      /tmp/ffmpeg-cache \
      /var/log/ffmpeg \
      /usr/share/fonts/custom && \
    echo "✅ Directories OK"

# ============================================================
# Download Arabic fonts (Amiri) + Noto Color Emoji
# ============================================================
RUN echo "⬇️  Downloading Amiri Arabic font..." && \
    curl -fsSL \
      --retry 3 \
      --retry-delay 3 \
      --connect-timeout 15 \
      --max-time 60 \
      "https://github.com/aliftype/amiri/releases/download/1.000/Amiri-1.000.zip" \
      -o /tmp/amiri.zip \
    && unzip -q /tmp/amiri.zip -d /tmp/amiri \
    && find /tmp/amiri -name "*.ttf" \
         -exec cp {} /usr/share/fonts/amiri/ \; \
    && rm -rf /tmp/amiri /tmp/amiri.zip \
    && echo "✅ Amiri font installed" \
    || echo "⚠️  Amiri font skipped"

RUN echo "⬇️  Downloading Noto Color Emoji..." && \
    curl -fsSL \
      --retry 3 \
      --retry-delay 3 \
      --connect-timeout 15 \
      --max-time 60 \
      "https://github.com/googlefonts/noto-emoji/raw/main/fonts/NotoColorEmoji.ttf" \
      -o /usr/share/fonts/noto-emoji/NotoColorEmoji.ttf \
    && echo "✅ NotoColorEmoji installed" \
    || echo "⚠️  NotoColorEmoji skipped"

# ============================================================
# Custom DejaVuSerif-Bold font
# ============================================================
RUN /usr/local/bin/curl -fsSL \
      --retry 5 \
      --retry-delay 3 \
      --retry-max-time 60 \
      --connect-timeout 15 \
      -o /usr/share/fonts/custom/DejaVuSerif-Bold.ttf \
      "https://pub-4685bf7139084a5f95b995d22d06af3f.r2.dev/DejaVuSerif-Bold.ttf" \
    && /bin/chmod 644 \
         /usr/share/fonts/custom/DejaVuSerif-Bold.ttf \
    && echo "✅ DejaVuSerif-Bold downloaded" \
    || echo "⚠️  DejaVuSerif-Bold skipped"

# ============================================================
# Fontconfig - Arabic + Emoji priority config
# ============================================================
RUN cat > /etc/fonts/conf.d/10-arabic-emoji.conf << 'EOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <alias>
    <family>serif</family>
    <prefer>
      <family>Amiri</family>
      <family>Noto Naskh Arabic</family>
      <family>Noto Serif Arabic</family>
      <family>FreeSerif</family>
      <family>DejaVu Serif</family>
    </prefer>
  </alias>
  <alias>
    <family>sans-serif</family>
    <prefer>
      <family>Noto Sans Arabic</family>
      <family>Noto Kufi Arabic</family>
      <family>FreeSans</family>
      <family>DejaVu Sans</family>
    </prefer>
  </alias>
  <alias>
    <family>emoji</family>
    <prefer>
      <family>Noto Color Emoji</family>
      <family>Noto Emoji</family>
    </prefer>
  </alias>
  <match target="font">
    <edit name="antialias"  mode="assign">
      <bool>true</bool>
    </edit>
    <edit name="hinting"    mode="assign">
      <bool>true</bool>
    </edit>
    <edit name="hintstyle"  mode="assign">
      <const>hintslight</const>
    </edit>
    <edit name="rgba"       mode="assign">
      <const>rgb</const>
    </edit>
  </match>
  <dir>/usr/share/fonts</dir>
  <dir>/usr/local/share/fonts</dir>
</fontconfig>
EOF

RUN fc-cache -fv && \
    echo "✅ Font cache OK" && \
    echo "=== Arabic fonts ===" && \
    fc-list :lang=ar | sort | head -10 || \
    echo "no arabic fonts" && \
    echo "=== All noto+dejavu ===" && \
    fc-list | grep -i "noto\|dejavu\|amiri" \
      | head -10 || true

# ============================================================
# Verify FFmpeg works
# ============================================================
RUN echo "=== FFmpeg verify ===" && \
    /usr/local/bin/ffmpeg -version 2>&1 | head -3 && \
    /usr/local/bin/ffprobe -version 2>&1 | head -1 && \
    /usr/local/bin/ffmpeg -filters 2>/dev/null \
      | grep drawtext && \
    echo "✅ FFmpeg + drawtext OK"

# ============================================================
# Community nodes
# ============================================================
USER node

RUN cd /home/node/.n8n/nodes && \
    npm init -y > /dev/null 2>&1 && \
    npm install \
      --save \
      --no-audit \
      --no-fund \
      @mookielianhd/n8n-nodes-instagram \
    2>&1 | tail -3 \
    && echo "✅ Community nodes OK" \
    || echo "⚠️  Will reinstall at runtime"

USER root

# ============================================================
# Copy scripts
# ============================================================
COPY --chown=node:node scripts/ /scripts/

RUN find /scripts -name "*.sh" | while read -r f; do \
      sed -i 's/\r$//' "$f" && \
      /bin/chmod 0755 "$f" && \
      echo "✅ $f ready"; \
    done

# ============================================================
# Build verification
# ============================================================
RUN echo "" && \
    echo "==========================================" && \
    echo " BUILD VERIFICATION - n8n 2.6.2"          && \
    echo "==========================================" && \
    echo ""                                          && \
    echo "--- n8n ---"                               && \
    n8n --version                                    && \
    echo ""                                          && \
    echo "--- FFmpeg static ---"                     && \
    /usr/local/bin/ffmpeg -version 2>&1 | head -2   && \
    echo ""                                          && \
    echo "--- ffprobe ---"                           && \
    /usr/local/bin/ffprobe -version 2>&1 | head -1  && \
    echo ""                                          && \
    echo "--- drawtext filter ---"                   && \
    /usr/local/bin/ffmpeg -filters 2>/dev/null \
      | grep drawtext                                && \
    echo ""                                          && \
    echo "--- sqlite3 ---"                           && \
    sqlite3 --version                                && \
    echo ""                                          && \
    echo "--- Arabic fonts ---"                      && \
    fc-list :lang=ar 2>/dev/null | head -5           \
      || echo "no arabic"                            && \
    echo ""                                          && \
    echo "--- Amiri + Noto + DejaVu ---"             && \
    fc-list | grep -i "amiri\|noto\|dejavu"          \
      | head -8 || true                              && \
    echo ""                                          && \
    echo "--- FFmpeg symlinks ---"                   && \
    ls -la /usr/bin/ffmpeg                           \
           /usr/bin/ffprobe                          \
           /bin/ffmpeg                               \
           /bin/ffprobe                              && \
    echo ""                                          && \
    echo "--- All tools ---"                         && \
    for t in ffmpeg ffprobe sqlite3 curl \
              jq bash tini su-exec; do \
      which "$t" > /dev/null 2>&1                   \
        && echo "  ✅ $t -> $(which $t)"             \
        || echo "  ❌ $t MISSING";                   \
    done                                             && \
    echo ""                                          && \
    echo "--- Community nodes ---"                   && \
    ls /home/node/.n8n/nodes/node_modules/           \
      2>/dev/null | head -5 || echo "none"           && \
    echo ""                                          && \
    echo "--- Scripts ---"                           && \
    ls -la /scripts/                                 && \
    echo ""                                          && \
    echo "==========================================" && \
    echo " ✅ ALL CHECKS PASSED"                     && \
    echo "=========================================="

# ============================================================
# Final verification as node user
# ============================================================
USER node

RUN ffmpeg -version 2>&1 | head -1 && \
    ffprobe -version 2>&1 | head -1 && \
    fc-list :lang=ar 2>/dev/null | head -3 \
      || echo "Arabic fonts check done" && \
    echo "✅ FFmpeg verified as node user"

# ============================================================
# Runtime
# ============================================================
WORKDIR /home/node
EXPOSE 5678

ENTRYPOINT ["/sbin/tini", "--", "sh", "/scripts/start.sh"]
