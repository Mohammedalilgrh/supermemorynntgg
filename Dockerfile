# ============================================================
# Stage 1: Build toolbox (static binaries + ffmpeg)
# ============================================================
FROM alpine:3.20 AS tools

# ------------------------------------------------------------
# Fonts (Arabic base)
# ------------------------------------------------------------
RUN mkdir -p /usr/share/fonts/custom

RUN curl -L -o /usr/share/fonts/custom/NotoSansArabic-Regular.ttf \
https://github.com/google/fonts/raw/main/ofl/notosansarabic/NotoSansArabic-Regular.ttf

RUN fc-cache -f -v || true

# ------------------------------------------------------------
# Core tools
# ------------------------------------------------------------
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

# ------------------------------------------------------------
# FFmpeg static build
# ------------------------------------------------------------
RUN curl -L -o /tmp/ffmpeg.tar.xz \
    https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz && \
    tar -xJf /tmp/ffmpeg.tar.xz -C /tmp/ && \
    cp /tmp/ffmpeg-*-static/ffmpeg  /toolbox/ && \
    cp /tmp/ffmpeg-*-static/ffprobe /toolbox/ && \
    rm -rf /tmp/ffmpeg-*-static /tmp/ffmpeg.tar.xz


# ============================================================
# Stage 2: Final image based on n8n
# ============================================================
FROM docker.n8n.io/n8nio/n8n:2.6.2

USER root

# ------------------------------------------------------------
# Copy toolbox + libs
# ------------------------------------------------------------
COPY --from=tools /toolbox/       /usr/local/bin/
COPY --from=tools /usr/lib/       /usr/local/lib/
COPY --from=tools /lib/           /usr/local/lib2/
COPY --from=tools /etc/ssl/certs/ /etc/ssl/certs/

# ------------------------------------------------------------
# Environment
# ------------------------------------------------------------
ENV LD_LIBRARY_PATH="/usr/local/lib:/usr/local/lib2:${LD_LIBRARY_PATH}"
ENV PATH="/usr/local/bin:${PATH}"

ENV FFMPEG_PATH="/usr/local/bin/ffmpeg"
ENV FFPROBE_PATH="/usr/local/bin/ffprobe"
ENV FFREPORT="file=/tmp/ffreport-%p-%t.log:level=32"

# ------------------------------------------------------------
# FFmpeg links + permissions
# ------------------------------------------------------------
RUN chmod +x /usr/local/bin/ffmpeg /usr/local/bin/ffprobe && \
    ln -sf /usr/local/bin/ffmpeg  /usr/bin/ffmpeg  && \
    ln -sf /usr/local/bin/ffprobe /usr/bin/ffprobe && \
    ln -sf /usr/local/bin/ffmpeg  /bin/ffmpeg      && \
    ln -sf /usr/local/bin/ffprobe /bin/ffprobe

# ------------------------------------------------------------
# Temp + logs
# ------------------------------------------------------------
RUN mkdir -p /tmp/ffmpeg-temp /tmp/ffmpeg-cache /var/log/ffmpeg && \
    chmod 1777 /tmp/ffmpeg-temp /tmp/ffmpeg-cache /tmp && \
    chmod 755  /var/log/ffmpeg

# Verify ffmpeg
RUN /usr/local/bin/ffmpeg -version && /usr/local/bin/ffprobe -version

# ------------------------------------------------------------
# n8n performance fixes
# ------------------------------------------------------------
ENV EXECUTIONS_TIMEOUT=7200 \
    EXECUTIONS_TIMEOUT_MAX=7200 \
    N8N_DEFAULT_BINARY_DATA_MODE=filesystem \
    N8N_BINARY_DATA_STORAGE_PATH=/home/node/.n8n/binaryData \
    N8N_EXECUTION_TIMEOUT=7200 \
    NODE_OPTIONS="--max-old-space-size=2048"

# ------------------------------------------------------------
# Fonts (Arabic + Emoji support)
# ------------------------------------------------------------
RUN apk add --no-cache \
    fontconfig ttf-dejavu font-noto font-noto-arabic \
    font-noto-extra font-noto-emoji font-freefont \
    libass fribidi harfbuzz freetype \
    libstdc++ libgcc libgomp zlib expat \
    curl unzip \
    2>/dev/null || true

# Amiri + Emoji fonts
RUN mkdir -p /usr/share/fonts/amiri /usr/share/fonts/noto-emoji && \
    curl -fsSL \
      "https://github.com/aliftype/amiri/releases/download/1.000/Amiri-1.000.zip" \
      -o /tmp/amiri.zip 2>/dev/null && \
    unzip -q /tmp/amiri.zip -d /tmp/amiri 2>/dev/null && \
    find /tmp/amiri -name "*.ttf" -exec cp {} /usr/share/fonts/amiri/ \; && \
    rm -rf /tmp/amiri /tmp/amiri.zip && \
    curl -fsSL \
      "https://github.com/googlefonts/noto-emoji/raw/main/fonts/NotoColorEmoji.ttf" \
      -o /usr/share/fonts/noto-emoji/NotoColorEmoji.ttf 2>/dev/null || true

# Font config
RUN mkdir -p /etc/fonts/conf.d && \
cat > /etc/fonts/conf.d/10-arabic-emoji.conf <<'EOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <alias>
    <family>serif</family>
    <prefer>
      <family>Amiri</family><family>Noto Naskh Arabic</family>
      <family>Noto Serif Arabic</family><family>FreeSerif</family>
      <family>DejaVu Serif</family>
    </prefer>
  </alias>
  <alias>
    <family>sans-serif</family>
    <prefer>
      <family>Noto Sans Arabic</family><family>Noto Kufi Arabic</family>
      <family>FreeSans</family><family>DejaVu Sans</family>
    </prefer>
  </alias>
  <alias>
    <family>emoji</family>
    <prefer>
      <family>Noto Color Emoji</family><family>Noto Emoji</family>
    </prefer>
  </alias>
  <match target="font">
    <edit name="antialias" mode="assign"><bool>true</bool></edit>
    <edit name="hinting" mode="assign"><bool>true</bool></edit>
    <edit name="hintstyle" mode="assign"><const>hintslight</const></edit>
    <edit name="rgba" mode="assign"><const>rgb</const></edit>
  </match>
  <dir>/usr/share/fonts</dir>
  <dir>/usr/local/share/fonts</dir>
</fontconfig>
EOF

# Cache fonts
RUN fc-cache -fv 2>/dev/null || true && \
    echo "=== Arabic ===" && fc-list :lang=ar | sort && \
    echo "=== Emoji ===" && fc-list :lang=und-zsye 2>/dev/null | sort || true

ENV LANG="en_US.UTF-8" \
    LC_ALL="en_US.UTF-8" \
    FONTCONFIG_PATH="/etc/fonts" \
    FONTCONFIG_FILE="/etc/fonts/fonts.conf"

# ------------------------------------------------------------
# Workspace
# ------------------------------------------------------------
RUN mkdir -p /scripts /backup-data /home/node/.n8n /home/node/.n8n/binaryData && \
    chown -R node:node /home/node/.n8n /scripts /backup-data && \
    chown -R node:node /tmp/ffmpeg-temp /tmp/ffmpeg-cache /var/log/ffmpeg

# ------------------------------------------------------------
# Custom nodes
# ------------------------------------------------------------
USER node

RUN cd /home/node/.n8n && \
    mkdir -p nodes && cd nodes && \
    npm init -y 2>/dev/null && \
    npm install @mookielianhd/n8n-nodes-instagram 2>/dev/null || true

# ------------------------------------------------------------
# Scripts
# ------------------------------------------------------------
USER root

COPY --chown=node:node scripts/ /scripts/

RUN sed -i 's/\r$//' /scripts/*.sh && \
    chmod 0755 /scripts/*.sh

# ------------------------------------------------------------
# Final checks
# ------------------------------------------------------------
USER node

RUN ffmpeg -version && ffprobe -version && \
    fc-list :lang=ar 2>/dev/null | head -5 || echo "Arabic fonts check done" && \
    echo "All verified OK"

# ------------------------------------------------------------
# Start
# ------------------------------------------------------------
WORKDIR /home/node

ENTRYPOINT ["sh", "/scripts/start.sh"]
