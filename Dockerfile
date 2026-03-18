# ==================================================
# STAGE 1: tools (Alpine) — Collect STATIC binaries and libraries
# ==================================================
FROM alpine:3.20 AS tools

RUN apk add --no-cache \
      curl jq sqlite tar gzip xz \
      coreutils findutils ca-certificates file && \
    mkdir -p /toolbox/bin /toolbox/lib /toolbox/piper-voices

# Copy common utilities to toolbox
RUN for cmd in curl jq sqlite3 split sha256sum \
               stat du sort tail awk xargs find \
               wc cut tr gzip tar cat date sleep \
               mkdir rm ls grep sed head touch \
               cp mv basename expr; do \
      p="$(which $cmd 2>/dev/null)" && \
        [ -f "$p" ] && cp "$p" /toolbox/bin/ || true; \
    done

# Copy required libraries
RUN cp -r /lib/* /toolbox/lib/ 2>/dev/null || true && \
    cp -r /usr/lib/* /toolbox/lib/ 2>/dev/null || true && \
    cp -r /etc/ssl/certs /toolbox/

# === Download STATIC FFmpeg (static build) ===
RUN echo "🎯 Downloading static FFmpeg..." && \
    curl -L -o /tmp/ffmpeg.tar.xz "https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz" && \
    tar -xJf /tmp/ffmpeg.tar.xz -C /tmp/ && \
    cp /tmp/ffmpeg-*-static/ffmpeg /toolbox/bin/ && \
    cp /tmp/ffmpeg-*-static/ffprobe /toolbox/bin/ && \
    rm -rf /tmp/ffmpeg-*-static /tmp/ffmpeg.tar.xz && \
    echo "✅ FFmpeg ready"

# === Download Piper (static binary) ===
RUN echo "🎯 Downloading Piper..." && \
    curl -fSL --connect-timeout 30 --retry 2 \
        "https://github.com/rhasspy/piper/releases/download/2023.11.14-2/piper_linux_x86_64.tar.gz" \
        -o /tmp/piper.tar.gz && \
    tar -xzf /tmp/piper.tar.gz -C /tmp/ && \
    cp /tmp/piper/piper /toolbox/bin/ && \
    rm -rf /tmp/piper* && \
    echo "✅ Piper ready"

# === Download Piper Voice Model ===
RUN echo "🎯 Downloading Piper model..." && \
    mkdir -p /toolbox/piper-voices && \
    curl -fSL --connect-timeout 30 --retry 2 \
        "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/vctk/medium/en_GB-vctk-medium.onnx" \
        -o /toolbox/piper-voices/en_GB-vctk-medium.onnx && \
    curl -fSL --connect-timeout 30 --retry 2 \
        "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/vctk/medium/en_GB-vctk-medium.onnx.json" \
        -o /toolbox/piper-voices/en_GB-vctk-medium.onnx.json && \
    echo "✅ Model ready"

# ==================================================
# STAGE 2: n8n — Final runtime (auto-detect package manager)
# ==================================================
FROM docker.n8n.io/n8nio/n8n:2.6.2

USER root

# Copy binaries, libraries, and models from tools stage
COPY --from=tools /toolbox/bin/          /usr/local/bin/
COPY --from=tools /toolbox/lib/          /usr/local/lib/
COPY --from=tools /toolbox/piper-voices/ /usr/local/piper-voices/
COPY --from=tools /toolbox/certs/        /etc/ssl/certs/

# Set library path
ENV LD_LIBRARY_PATH="/usr/local/lib:/usr/lib:/lib:$LD_LIBRARY_PATH"
ENV PATH="/usr/local/bin:$PATH"

# Make binaries executable
RUN chmod +x /usr/local/bin/ffmpeg /usr/local/bin/ffprobe /usr/local/bin/piper

# Detect package manager and install dependencies
RUN if command -v apt-get >/dev/null 2>&1; then \
        echo "Using apt-get (Debian/Ubuntu)..." && \
        apt-get update && apt-get install -y --no-install-recommends \
            curl jq sqlite3 coreutils findutils ca-certificates \
            fontconfig fonts-dejavu fonts-noto fonts-noto-core fonts-noto-arabic \
            libass9 libfribidi0 libharfbuzz0b libfreetype6 \
            libstdc++6 libgomp1 zlib1g libexpat1 \
            && rm -rf /var/lib/apt/lists/*; \
    elif command -v apk >/dev/null 2>&1; then \
        echo "Using apk (Alpine)..." && \
        apk add --no-cache \
            curl jq sqlite coreutils findutils ca-certificates \
            fontconfig ttf-dejavu font-noto font-noto-arabic \
            libass fribidi harfbuzz freetype \
            libstdc++ libgomp zlib expat \
            && fc-cache -fv; \
    else \
        echo "WARNING: No known package manager found. Skipping dependency installation."; \
    fi

# Create required directories with proper permissions
RUN mkdir -p /tmp/ffmpeg-temp /tmp/ffmpeg-cache /var/log/ffmpeg \
    /scripts /backup-data /home/node/.n8n && \
    chmod 1777 /tmp/ffmpeg-temp /tmp/ffmpeg-cache /tmp && \
    chmod 755 /var/log/ffmpeg && \
    chown -R node:node /home/node/.n8n /scripts /backup-data \
    /tmp/ffmpeg-temp /tmp/ffmpeg-cache /var/log/ffmpeg

# Create symlinks for common paths
RUN ln -sf /usr/local/bin/ffmpeg /usr/bin/ffmpeg 2>/dev/null || true && \
    ln -sf /usr/local/bin/ffprobe /usr/bin/ffprobe 2>/dev/null || true && \
    ln -sf /usr/local/bin/ffmpeg /bin/ffmpeg 2>/dev/null || true && \
    ln -sf /usr/local/bin/ffprobe /bin/ffprobe 2>/dev/null || true

# Verify binaries work
RUN /usr/local/bin/ffmpeg -version > /dev/null 2>&1 && echo "✅ FFmpeg OK" || echo "⚠️ FFmpeg check failed" && \
    /usr/local/bin/ffprobe -version > /dev/null 2>&1 && echo "✅ FFprobe OK" || echo "⚠️ FFprobe check failed" && \
    /usr/local/bin/piper --version > /dev/null 2>&1 && echo "✅ Piper OK" || echo "⚠️ Piper check failed"

# Environment variables
ENV FFMPEG_PATH="/usr/local/bin/ffmpeg"
ENV FFPROBE_PATH="/usr/local/bin/ffprobe"
ENV FFREPORT="file=/tmp/ffreport-%p-%t.log:level=32"
ENV PIPER_MODEL="/usr/local/piper-voices/en_GB-vctk-medium.onnx"
ENV PIPER_SPEAKER="9"

# Robust TTS Script
RUN cat > /usr/local/bin/tts-en << 'EOF'
#!/bin/bash
set -euo pipefail
TEXT="$1"
OUTPUT="${2:-/tmp/tts_out.wav}"
[ -z "$TEXT" ] && { echo "Error: No text" >&2; exit 1; }
mkdir -p "$(dirname "$OUTPUT")"
case "${OUTPUT##*.}" in
    mp3)
        TMP_WAV="$(mktemp --suffix=.wav)"
        trap 'rm -f "$TMP_WAV"' EXIT
        echo "$TEXT" | piper --model "$PIPER_MODEL" --speaker "$PIPER_SPEAKER" --output_file "$TMP_WAV"
        ffmpeg -y -hide_banner -loglevel error -i "$TMP_WAV" -codec:a libmp3lame -qscale:a 2 "$OUTPUT"
        echo "✅ MP3: $OUTPUT"
        ;;
    *) echo "$TEXT" | piper --model "$PIPER_MODEL" --speaker "$PIPER_SPEAKER" --output_file "$OUTPUT"
        echo "✅ WAV: $OUTPUT" ;;
esac
EOF
RUN chmod +x /usr/local/bin/tts-en

# Install Instagram Node (as node user)
USER node
RUN mkdir -p /home/node/.n8n/nodes && \
    cd /home/node/.n8n/nodes && \
    npm init -y --silent 2>/dev/null || true && \
    npm install @mookielianhd/n8n-nodes-instagram --silent 2>/dev/null || true

# Copy startup scripts
USER root
COPY --chown=node:node scripts/ /scripts/
RUN if [ -d /scripts ]; then \
        find /scripts -type f -name "*.sh" -exec sed -i 's/\r$//' {} \; && \
        chmod 0755 /scripts/*.sh 2>/dev/null || true; \
    fi

# Final verification as node user
USER node
RUN echo "🧪 Testing TTS functionality..." && \
    if command -v tts-en >/dev/null 2>&1; then \
        tts-en "Hello from Piper TTS on n8n!" /tmp/test_tts.wav && \
        if [ -s /tmp/test_tts.wav ]; then \
            echo "✅ TTS test passed"; \
        else \
            echo "⚠️ TTS test produced empty file"; \
        fi; \
    else \
        echo "⚠️ TTS script not found, skipping test"; \
    fi

WORKDIR /home/node

# Use existing entrypoint or create a default one
RUN if [ ! -f /scripts/start.sh ]; then \
        echo '#!/bin/sh\ncd /home/node\n exec n8n' > /scripts/start.sh && \
        chmod +x /scripts/start.sh; \
    fi

ENTRYPOINT ["sh", "/scripts/start.sh"]
