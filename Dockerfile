# ─────────────────────────────────────────────────────────────
# Stage 1: Minimal tools builder
# ─────────────────────────────────────────────────────────────
FROM alpine:3.20 AS tools

# Install only essential packages
RUN apk add --no-cache \
      curl xz \
      python3 \
      fontconfig ttf-dejavu font-noto-arabic \
      libass fribidi harfbuzz freetype \
      binutils

# Create toolbox with ONLY essential binaries
RUN mkdir -p /toolbox /libs && \
    for cmd in python3 fc-cache fc-list; do \
      p="$(which $cmd 2>/dev/null)" && [ -f "$p" ] && cp "$p" /toolbox/ || true; \
    done

# Download and extract ffmpeg - keep only essentials
RUN curl -L -o /tmp/ff.tar.xz https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz && \
    tar -xJf /tmp/ff.tar.xz -C /tmp/ && \
    cp /tmp/ffmpeg-*-static/ffmpeg /tmp/ffmpeg-*-static/ffprobe /toolbox/ && \
    strip /toolbox/ffmpeg /toolbox/ffprobe 2>/dev/null || true && \
    rm -rf /tmp/*

# Copy ONLY required libraries (not entire /usr/lib)
RUN for lib in \
      libpython3*.so* \
      libfontconfig.so* \
      libfreetype.so* \
      libfribidi.so* \
      libharfbuzz.so* \
      libass.so* \
      libexpat.so* \
      libbz2.so* \
      libpng*.so* \
      libbrotli*.so* \
      libgraphite2.so* \
      libintl.so*; do \
    find /usr/lib -name "$lib" -exec cp {} /libs/ \; 2>/dev/null || true; \
    done

# Python stdlib - minimal copy
RUN PYVER=$(python3 -c "import sys;print(f'{sys.version_info.major}.{sys.version_info.minor}')") && \
    mkdir -p /pylib && \
    cp -r /usr/lib/python${PYVER} /pylib/ && \
    echo "$PYVER" > /pylib/version.txt && \
    find /pylib -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true && \
    find /pylib -name "*.pyc" -delete 2>/dev/null || true && \
    find /pylib -type d -name "test*" -exec rm -rf {} + 2>/dev/null || true && \
    find /pylib -type d -name "idle*" -exec rm -rf {} + 2>/dev/null || true && \
    find /pylib -type d -name "tkinter" -exec rm -rf {} + 2>/dev/null || true && \
    find /pylib -type d -name "turtle*" -exec rm -rf {} + 2>/dev/null || true

# Minimal fonts - only Arabic + fallback
RUN mkdir -p /fonts && \
    cp -r /usr/share/fonts/noto /fonts/ 2>/dev/null || true && \
    cp -r /usr/share/fonts/dejavu /fonts/ 2>/dev/null || true && \
    fc-cache -f 2>/dev/null || true

# ─────────────────────────────────────────────────────────────
# Stage 2: Final optimized n8n image
# ─────────────────────────────────────────────────────────────
FROM docker.n8n.io/n8nio/n8n:2.6.2

USER root

# Copy binaries
COPY --from=tools /toolbox/ffmpeg     /usr/local/bin/
COPY --from=tools /toolbox/ffprobe    /usr/local/bin/
COPY --from=tools /toolbox/python3    /usr/local/bin/
COPY --from=tools /toolbox/fc-cache   /usr/local/bin/
COPY --from=tools /toolbox/fc-list    /usr/local/bin/

# Copy only required libs
COPY --from=tools /libs/              /usr/local/lib/

# Copy minimal Python stdlib
COPY --from=tools /pylib/             /usr/lib/pylib/

# Copy fonts
COPY --from=tools /fonts/             /usr/share/fonts/
COPY --from=tools /etc/fonts/         /etc/fonts/
COPY --from=tools /var/cache/fontconfig/ /var/cache/fontconfig/

# All ENV in one layer
ENV LD_LIBRARY_PATH="/usr/local/lib:/usr/lib" \
    PATH="/usr/local/bin:$PATH" \
    FFMPEG_PATH="/usr/local/bin/ffmpeg" \
    FFPROBE_PATH="/usr/local/bin/ffprobe" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# Setup everything in ONE RUN command for minimal layers
RUN PYVER=$(cat /usr/lib/pylib/version.txt) && \
    \
    # Python setup
    ln -sf /usr/lib/pylib/python${PYVER} /usr/lib/python${PYVER} && \
    echo "export PYTHONPATH=/usr/lib/python${PYVER}" >> /etc/profile && \
    \
    # Symlinks for binaries
    ln -sf /usr/local/bin/ffmpeg /usr/bin/ffmpeg && \
    ln -sf /usr/local/bin/ffprobe /usr/bin/ffprobe && \
    ln -sf /usr/local/bin/python3 /usr/bin/python3 && \
    ln -sf /usr/local/bin/python3 /usr/bin/python && \
    \
    # Directories
    mkdir -p /scripts /backup-data /home/node/.n8n && \
    chown -R node:node /home/node/.n8n /scripts /backup-data && \
    \
    # Font cache
    fc-cache -f 2>/dev/null || true && \
    \
    # Make executable
    chmod +x /usr/local/bin/*

# Set PYTHONPATH dynamically
RUN PYVER=$(cat /usr/lib/pylib/version.txt) && \
    echo "PYTHONPATH=/usr/lib/python${PYVER}" >> /etc/environment

ENV PYTHONPATH="/usr/lib/python3.12"

# Install n8n nodes
USER node
RUN cd /home/node/.n8n && \
    mkdir -p nodes && cd nodes && \
    npm init -y 2>/dev/null && \
    npm install --prefer-offline --no-audit --no-fund @mookielianhd/n8n-nodes-instagram 2>/dev/null || true

USER root

# Copy scripts
COPY --chown=node:node scripts/ /scripts/
RUN sed -i 's/\r$//' /scripts/*.sh 2>/dev/null || true && \
    chmod 0755 /scripts/*.sh 2>/dev/null || true

# Quick verification
USER node
RUN ffmpeg -version | head -1 && \
    ffprobe -version | head -1 && \
    PYVER=$(cat /usr/lib/pylib/version.txt) && \
    PYTHONPATH="/usr/lib/python${PYVER}" python3 -c "print('OK')" && \
    echo "BUILD OK"

WORKDIR /home/node
ENTRYPOINT ["sh", "/scripts/start.sh"]
