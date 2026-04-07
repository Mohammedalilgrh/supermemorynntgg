# ============================================================
#  STAGE 1 – FFmpeg static binary (amd64)
# ============================================================
FROM alpine:3.20 AS ffmpeg-builder

RUN apk add --no-cache curl xz

# Pull latest static build (GPL, all codecs including libass/fribidi/harfbuzz)
RUN curl -fsSL -o /tmp/ffmpeg.tar.xz \
      "https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz" && \
    tar -xJf /tmp/ffmpeg.tar.xz -C /tmp/ && \
    install -m 0755 /tmp/ffmpeg-*-static/ffmpeg  /ffmpeg && \
    install -m 0755 /tmp/ffmpeg-*-static/ffprobe /ffprobe && \
    rm -rf /tmp/ffmpeg*

# ============================================================
#  STAGE 2 – CLI tool-box (Alpine)
# ============================================================
FROM alpine:3.20 AS tools-builder

RUN apk add --no-cache \
      curl jq sqlite tar gzip xz \
      coreutils findutils ca-certificates

RUN mkdir -p /toolbox && \
    for cmd in \
      curl jq sqlite3 split sha256sum stat du sort \
      tail awk xargs find wc cut tr gzip tar cat  \
      date sleep mkdir rm ls grep sed head touch  \
      cp mv basename expr; \
    do \
      p="$(which "$cmd" 2>/dev/null)" && \
        [ -f "$p" ] && cp "$p" /toolbox/ || true; \
    done

# ============================================================
#  STAGE 3 – Arabic / CJK font collection (Alpine)
# ============================================================
FROM alpine:3.20 AS fonts-builder

# Install every font package available in Alpine 3.20 that covers Arabic
RUN apk add --no-cache \
      fontconfig \
      # ── DejaVu (base Latin / math)
      ttf-dejavu \
      # ── Noto family – covers Arabic, Arabic Supplement, Arabic Extended
      font-noto \
      font-noto-arabic \
      font-noto-extra \
      # ── Liberation (metric-compatible with MS fonts)
      ttf-liberation \
      # ── FreeFonts (wide Unicode coverage including Arabic)
      font-freefont \
      # ── Droid (legacy Android Arabic glyphs)
      font-droid-nonlatin \
      # ── Supporting libs
      freetype \
      libpng \
      expat \
      2>/dev/null || true

# ── Download Amiri (classical/Quranic Arabic) from GitHub releases
RUN apk add --no-cache curl && \
    mkdir -p /usr/share/fonts/amiri && \
    curl -fsSL \
      "https://github.com/aliftype/amiri/releases/download/1.000/Amiri-1.000.zip" \
      -o /tmp/amiri.zip 2>/dev/null && \
    ( cd /tmp && unzip -q amiri.zip 2>/dev/null || true ) && \
    find /tmp -name "*.ttf" -path "*/Amiri*" -exec \
      cp {} /usr/share/fonts/amiri/ \; 2>/dev/null || true && \
    rm -rf /tmp/amiri* || true

# ── Build fontconfig cache so it ships pre-warmed
RUN fc-cache -fv 2>/dev/null || true && \
    fc-list :lang=ar | sort > /arabic-fonts.list && \
    echo "=== Arabic fonts found ===" && cat /arabic-fonts.list

# ============================================================
#  STAGE 4 – Final n8n image
# ============================================================
FROM docker.n8n.io/n8nio/n8n:2.6.2

# ── Switch to root for installation
USER root

# ── Copy static binaries from builder stages
COPY --from=ffmpeg-builder /ffmpeg  /usr/local/bin/ffmpeg
COPY --from=ffmpeg-builder /ffprobe /usr/local/bin/ffprobe
COPY --from=tools-builder  /toolbox/ /usr/local/bin/

# ── Copy CA certificates (needed for HTTPS inside n8n workflows)
COPY --from=tools-builder /etc/ssl/certs/ /etc/ssl/certs/

# ── Copy full font tree + pre-warmed cache
COPY --from=fonts-builder /usr/share/fonts/        /usr/share/fonts/
COPY --from=fonts-builder /etc/fonts/              /etc/fonts/
# Pre-warmed fontconfig cache → no fc-cache cold-start at runtime
COPY --from=fonts-builder /var/cache/fontconfig/   /var/cache/fontconfig/

# ── Install ONLY the runtime shared libs required (no build tools)
#    These back libass, fribidi, harfbuzz, freetype inside the n8n image.
RUN apk add --no-cache \
      # Font rendering pipeline
      fontconfig \
      freetype \
      libpng \
      # Bidi / shaping (Arabic right-to-left text)
      fribidi \
      harfbuzz \
      # ASS/SSA subtitle renderer (used by ffmpeg drawtext/subtitles)
      libass \
      # C++ / OpenMP runtimes (needed by static ffmpeg)
      libstdc++ \
      libgcc \
      libgomp \
      # Compression libs
      zlib \
      xz-libs \
      # XML / expat (fontconfig dependency)
      expat \
      # Useful in workflows
      jq \
      curl \
      sqlite \
      # Python (for n8n Python nodes) – lightweight
      python3 \
      2>/dev/null || true

# ── Rebuild fontconfig cache inside the final image to pick up all paths
RUN fc-cache -fv 2>/dev/null || true

# ── Symlinks so every possible path resolves
RUN for bin in ffmpeg ffprobe; do \
      ln -sf /usr/local/bin/$bin /usr/bin/$bin; \
      ln -sf /usr/local/bin/$bin /bin/$bin; \
    done

# ── Runtime directory layout
RUN mkdir -p \
      /tmp/ffmpeg-temp \
      /tmp/ffmpeg-cache \
      /var/log/ffmpeg \
      /scripts \
      /backup-data \
      /home/node/.n8n/nodes && \
    chmod 1777 /tmp/ffmpeg-temp /tmp/ffmpeg-cache /tmp && \
    chmod 755  /var/log/ffmpeg && \
    chown -R node:node \
      /home/node/.n8n \
      /scripts \
      /backup-data \
      /tmp/ffmpeg-temp \
      /tmp/ffmpeg-cache \
      /var/log/ffmpeg

# ── n8n performance tuning
ENV NODE_OPTIONS="--max-old-space-size=4096 --max-semi-space-size=128" \
    UV_THREADPOOL_SIZE=16 \
    NODE_ENV=production

# ── FFmpeg environment
ENV FFMPEG_PATH="/usr/local/bin/ffmpeg" \
    FFPROBE_PATH="/usr/local/bin/ffprobe" \
    FFREPORT="file=/tmp/ffreport-%p-%t.log:level=32"

# ── Fontconfig / Arabic rendering environment
#    FONTCONFIG_PATH → where fontconfig reads its confs
#    FONTCONFIG_FILE → explicit fonts.conf (fontconfig fallback)
#    FC_LANG         → default language hint for font selection
#    LANG / LC_ALL   → full UTF-8 locale so Arabic bytes round-trip correctly
ENV FONTCONFIG_PATH="/etc/fonts" \
    FONTCONFIG_FILE="/etc/fonts/fonts.conf" \
    FC_LANG="ar" \
    LANG="en_US.UTF-8" \
    LC_ALL="en_US.UTF-8" \
    # Pre-warmed cache dir shipped from builder
    XDG_CACHE_HOME="/var/cache"

# ── Drop a comprehensive fontconfig conf that prioritises Arabic fonts
RUN mkdir -p /etc/fonts/conf.d && cat > /etc/fonts/conf.d/10-arabic-prefer.conf <<'EOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>

  <!-- ── Prefer order for Arabic script ── -->
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
    <family>monospace</family>
    <prefer>
      <family>Noto Sans Arabic</family>
      <family>FreeMono</family>
      <family>DejaVu Sans Mono</family>
    </prefer>
  </alias>

  <!-- ── Enable sub-pixel rendering & hinting ── -->
  <match target="font">
    <edit name="antialias"  mode="assign"><bool>true</bool></edit>
    <edit name="hinting"    mode="assign"><bool>true</bool></edit>
    <edit name="hintstyle"  mode="assign"><const>hintslight</const></edit>
    <edit name="rgba"       mode="assign"><const>rgb</const></edit>
    <edit name="lcdfilter"  mode="assign"><const>lcddefault</const></edit>
  </match>

  <!-- ── Scan all font dirs ── -->
  <dir>/usr/share/fonts</dir>
  <dir>/usr/local/share/fonts</dir>
  <dir>/home/node/.fonts</dir>

</fontconfig>
EOF

# ── Install community n8n nodes as node user
USER node
RUN cd /home/node/.n8n/nodes && \
    npm init -y 2>/dev/null && \
    npm install \
      @mookielianhd/n8n-nodes-instagram \
    2>/dev/null || true

# ── Back to root for final script copy
USER root
COPY --chown=node:node scripts/ /scripts/
RUN sed -i 's/\r$//' /scripts/*.sh && \
    chmod 0755 /scripts/*.sh

# ── Final sanity checks (fail the build early if anything is broken)
RUN /usr/local/bin/ffmpeg  -version | head -3 && \
    /usr/local/bin/ffprobe -version | head -3 && \
    fc-list :lang=ar | wc -l | \
      xargs -I{} sh -c 'echo "Arabic fonts available: {}" && [ {} -gt 0 ]' && \
    echo "✅ All checks passed"

USER node
WORKDIR /home/node
ENTRYPOINT ["sh", "/scripts/start.sh"]
