# ==================================================
# STAGE 1: tools (Alpine) — Collect STATIC binaries
# ==================================================
FROM alpine:3.20 AS tools

# Install minimal tools for downloading and packaging
RUN apk add --no-cache \
      curl tar gzip xz findutils ca-certificates \
      && rm -rf /var/cache/apk/*

# Directory to collect tools
RUN mkdir -p /toolbox /tmp/piper-bin /tmp/piper-voices

# === Download STATIC FFmpeg (Alpine-compatible static build) ===
RUN curl -L -o /tmp/ffmpeg.tar.xz \
    https://github.com/BtbN/FFmpeg-Builds/releases/download/autobuild-20240715-1212/ffmpeg-master-latest-alpine-amd64-static.tar.xz \
    && tar -xJf /tmp/ffmpeg.tar.xz -C /tmp --strip-components=1 \
    && cp /tmp/ffmpeg /tmp/ffprobe /toolbox/ \
    && rm -rf /tmp/ffmpeg*

# === Download Piper (statically linked Linux binary) ===
RUN curl -L -o /tmp/piper.tar.gz \
    https://github.com/rhasspy/piper/releases/download/2023.11.14-2/piper_linux_x86_64.tar.gz \
    && mkdir -p /tmp/piper-bin \
    && tar -xzf /tmp/piper.tar.gz -C /tmp/piper-bin --strip-components=1 \
    && cp /tmp/piper-bin/piper /toolbox/ \
    && rm -rf /tmp/piper*

# === Download Piper Voice Model (en_GB-vctk-medium) ===
RUN mkdir -p /tmp/piper-voices \
    && curl -L -o /tmp/piper-voices/en_GB-vctk-medium.onnx \
       https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/vctk/medium/en_GB-vctk-medium.onnx \
    && curl -L -o /tmp/piper-voices/en_GB-vctk-medium.onnx.json \
       https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/vctk/medium/en_GB-vctk-medium.onnx.json

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

# Environment variables
ENV FFMPEG_PATH="/usr/local/bin/ffmpeg"
ENV FFPROBE_PATH="/usr/local/bin/ffprobe"
ENV FFREPORT="file=/tmp/ffreport-%p-%t.log:level=32"
ENV PIPER_MODEL="/usr/local/piper-voices/en_GB-vctk-medium.onnx"
ENV PIPER_SPEAKER="9"
ENV PATH="/usr/local/bin:$PATH"

# Robust TTS Script with error handling
RUN cat > /usr/local/bin/tts-en << 'EOF'
#!/bin/bash
set -euo pipefail

# Usage: tts-en "Text" [/path/to/output.wav|mp3]
TEXT="$1"
OUTPUT="${2:-/tmp/tts_out.wav}"

# Validate input
if [ -z "$TEXT" ]; then
    echo "Error: No text provided" >&2
    exit 1
fi

mkdir -p "$(dirname "$OUTPUT")"

case "${OUTPUT##*.}" in
    mp3)
        TMP_WAV="$(mktemp --suffix=.wav)"
        trap 'rm -f "$TMP_WAV"' EXIT
        echo "$TEXT" | piper \
            --model "$PIPER_MODEL" \
            --speaker "$PIPER_SPEAKER" \
            --output_file "$TMP_WAV"
        ffmpeg -y -hide_banner -loglevel error -i "$TMP_WAV" \
               -codec:a libmp3lame -qscale:a 2 "$OUTPUT"
        echo "✅ MP3 saved: $OUTPUT"
        ;;
    wav|*)
        echo "$TEXT" | piper \
            --model "$PIPER_MODEL" \
            --speaker "$PIPER_SPEAKER" \
            --output_file "$OUTPUT"
        echo "✅ WAV saved: $OUTPUT"
        ;;
esac
EOF
RUN chmod +x /usr/local/bin/tts-en

# Install Instagram Node (as node user)
USER node
RUN mkdir -p /home/node/.n8n/nodes \
    && cd /home/node/.n8n/nodes \
    && npm init -y --silent \
    && npm install @mookielianhd/n8n-nodes-instagram --silent || true

# Setup directories and permissions
USER root
RUN mkdir -p /scripts /backup-data /home/node/.n8n \
    && chown -R node:node /scripts /backup-data /home/node/.n8n \
    && chown -R node:node /tmp/ffmpeg-temp /tmp/ffmpeg-cache /var/log/ffmpeg

# Copy user scripts
COPY --chown=node:node scripts/ /scripts/
RUN sed -i 's/\r$//' /scripts/*.sh \
    && chmod 0755 /scripts/*.sh

# Final Verification (as node user)
USER node
RUN echo "🧪 Running final tests..." && \
    echo "🔧 Testing FFmpeg..." && \
    /usr/local/bin/ffmpeg -version && \
    /usr/local/bin/ffprobe -version && \
    echo "🎙️ Testing Piper binary..." && \
    /usr/local/bin/piper --version && \
    echo "🔊 Generating test audio..." && \
    tts-en "Hello from Piper TTS on n8n! This works perfectly." /tmp/test_tts.mp3 && \
    [ -s /tmp/test_tts.mp3 ] && echo "✅ Test MP3 generated: $(stat -c%s /tmp/test_tts.mp3) bytes" || (echo "❌ MP3 generation failed" && exit 1) && \
    echo "📂 Piper voices:" && \
    ls -lh /usr/local/piper-voices/ && \
    echo "✅ All tests passed. Build complete."

# Default working dir and entrypoint
WORKDIR /home/node
ENTRYPOINT ["sh", "/scripts/start.sh"]
