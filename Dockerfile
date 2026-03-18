# ==================================================
# STAGE 1: tools (Alpine) — Collect STATIC binaries
# ==================================================
FROM alpine:3.20 AS tools

RUN apk add --no-cache curl tar gzip xz findutils ca-certificates file

RUN mkdir -p /toolbox /tmp/piper-bin /tmp/piper-voices

# === Download STATIC FFmpeg (Alpine/musl) ===
RUN echo "🎯 Downloading static FFmpeg..." && \
    curl -fSL --connect-timeout 30 --retry 2 \
        "https://github.com/BtbN/FFmpeg-Builds/releases/download/autobuild-2024-11-10-12-56/ffmpeg-n7.1-latest-linux64-musl-7.1.tar.xz" \
        -o /tmp/ffmpeg.tar.xz && \
    echo "✅ FFmpeg: $(stat -c%s /tmp/ffmpeg.tar.xz) bytes" && \
    tar -xJf /tmp/ffmpeg.tar.xz -C /tmp --strip-components=1 && \
    cp /tmp/ffmpeg /tmp/ffprobe /toolbox/ && \
    rm -rf /tmp/ffmpeg* && \
    echo "✅ FFmpeg ready"

# === Download Piper (static binary) ===
RUN echo "🎯 Downloading Piper..." && \
    curl -fSL --connect-timeout 30 --retry 2 \
        "https://github.com/rhasspy/piper/releases/download/2023.11.14-2/piper_linux_x86_64.tar.gz" \
        -o /tmp/piper.tar.gz && \
    echo "✅ Piper: $(stat -c%s /tmp/piper.tar.gz) bytes" && \
    tar -xzf /tmp/piper.tar.gz -C /tmp/piper-bin --strip-components=1 && \
    cp /tmp/piper-bin/piper /toolbox/ && \
    rm -rf /tmp/piper* && \
    echo "✅ Piper ready"

# === Download Piper Voice Model ===
RUN echo "🎯 Downloading Piper model..." && \
    mkdir -p /tmp/piper-voices && \
    curl -fSL --connect-timeout 30 --retry 2 \
        "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/vctk/medium/en_GB-vctk-medium.onnx" \
        -o /tmp/piper-voices/en_GB-vctk-medium.onnx && \
    curl -fSL --connect-timeout 30 --retry 2 \
        "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/vctk/medium/en_GB-vctk-medium.onnx.json" \
        -o /tmp/piper-voices/en_GB-vctk-medium.onnx.json && \
    echo "✅ Model ready"

# ==================================================
# STAGE 2: n8n (Debian) — Final runtime
# ==================================================
FROM docker.n8n.io/n8nio/n8n:2.6.2

USER root

# Copy binaries from tools stage
COPY --from=tools /toolbox/ffmpeg /usr/local/bin/ffmpeg
COPY --from=tools /toolbox/ffprobe /usr/local/bin/ffprobe
COPY --from=tools /toolbox/piper /usr/local/bin/piper
COPY --from=tools /tmp/piper-voices/ /usr/local/piper-voices/

# Make binaries executable
RUN chmod +x /usr/local/bin/ffmpeg /usr/local/bin/ffprobe /usr/local/bin/piper

# Symlinks
RUN ln -sf /usr/local/bin/ffmpeg /usr/bin/ffmpeg /bin/ffmpeg \
    && ln -sf /usr/local/bin/ffprobe /usr/bin/ffprobe /bin/ffprobe

# Install Debian dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl jq sqlite3 coreutils findutils ca-certificates \
    fontconfig fonts-dejavu fonts-noto fonts-noto-core fonts-noto-arabic \
    libass9 libfribidi0 libharfbuzz0b libfreetype6 \
    libstdc++6 zlib1g libexpat1 \
    && rm -rf /var/lib/apt/lists/*

# Update font cache
RUN fc-cache -fv

# Create required directories
RUN mkdir -p /tmp/ffmpeg-temp /tmp/ffmpeg-cache /var/log/ffmpeg \
    && chmod 1777 /tmp/ffmpeg-temp /tmp/ffmpeg-cache /tmp \
    && chmod 755 /var/log/ffmpeg

# Environment variables (DO NOT override PATH)
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

# Install Instagram Node
USER node
RUN mkdir -p /home/node/.n8n/nodes \
    && cd /home/node/.n8n/nodes \
    && npm init -y --silent \
    && npm install @mookielianhd/n8n-nodes-instagram --silent || true

# Setup scripts
USER root
RUN mkdir -p /scripts /backup-data /home/node/.n8n \
    && chown -R node:node /scripts /backup-data /home/node/.n8n \
    && chown -R node:node /tmp/ffmpeg-temp /tmp/ffmpeg-cache /var/log/ffmpeg
COPY --chown=node:node scripts/ /scripts/
RUN sed -i 's/\r$//' /scripts/*.sh && chmod 0755 /scripts/*.sh

# Final Verification
USER node
RUN echo "🧪 Testing FFmpeg..." && \
    /usr/local/bin/ffmpeg -version && \
    echo "🧪 Testing Piper..." && \
    /usr/local/bin/piper --version && \
    echo "🧪 Testing TTS..." && \
    tts-en "Hello from Piper TTS on n8n! This works perfectly." /tmp/test_tts.mp3 && \
    [ -s /tmp/test_tts.mp3 ] && echo "✅ SUCCESS: $(stat -c%s /tmp/test_tts.mp3) bytes" || \
    (echo "❌ FAILED: Zero KB file" && exit 1)

WORKDIR /home/node
ENTRYPOINT ["sh", "/scripts/start.sh"]
