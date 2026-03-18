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

# === Download STATIC FFmpeg (Alpine-compatible, from static-ffmpeg.gitlab.io) ===
# Latest stable static FFmpeg for Alpine x86_64
ENV FFMPEG_URL="https://static-ffmpeg.gitlab.io/stable/linux/static_x86_64_alpine/ffmpeg-static-x86_64-alpine.tar.xz"
ENV FFMPEG_ARCHIVE="ffmpeg-static-x86_64-alpine.tar.xz"

RUN curl -fSL "$FFMPEG_URL" -o "/tmp/$FFMPEG_ARCHIVE" \
    && echo "✅ FFmpeg downloaded: $(stat -c%s "/tmp/$FFMPEG_ARCHIVE") bytes" \
    && mkdir -p /tmp/ffmpeg-extracted \
    && tar -xJf "/tmp/$FFMPEG_ARCHIVE" -C "/tmp/ffmpeg-extracted" --strip-components=1 \
    && cp "/tmp/ffmpeg-extracted/ffmpeg" "/tmp/ffmpeg-extracted/ffprobe" /toolbox/ \
    && rm -rf "/tmp/ffmpeg-extracted" "/tmp/$FFMPEG_ARCHIVE" \
    || (echo "❌ Failed to download or extract FFmpeg from $FFMPEG_URL" && exit 1)

# === Download Piper (statically linked Linux binary) ===
ENV PIPER_URL="https://github.com/rhasspy/piper/releases/download/2023.11.14-2/piper_linux_x86_64.tar.gz"
ENV PIPER_ARCHIVE="piper_linux_x86_64.tar.gz"

RUN mkdir -p /tmp/piper-bin \
    && curl -fSL "$PIPER_URL" -o "/tmp/$PIPER_ARCHIVE" \
    && echo "✅ Piper downloaded: $(stat -c%s "/tmp/$PIPER_ARCHIVE") bytes" \
    && tar -xzf "/tmp/$PIPER_ARCHIVE" -C /tmp/piper-bin --strip-components=1 \
    && cp /tmp/piper-bin/piper /toolbox/ \
    && rm -rf /tmp/piper* \
    || (echo "❌ Failed to download Piper from $PIPER_URL" && exit 1)

# === Download Piper Voice Model (en_GB-vctk-medium) ===
ENV MODEL_URL_ONNX="https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/vctk/medium/en_GB-vctk-medium.onnx"
ENV MODEL_URL_JSON="https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/vctk/medium/en_GB-vctk-medium.onnx.json"

RUN mkdir -p /tmp/piper-voices \
    && curl -fSL "$MODEL_URL_ONNX" -o "/tmp/piper-voices/en_GB-vctk-medium.onnx" \
    && echo "✅ Model ONNX downloaded" \
    && curl -fSL "$MODEL_URL_JSON" -o "/tmp/piper-voices/en_GB-vctk-medium.onnx.json" \
    && echo "✅ Model JSON downloaded" \
    || (echo "❌ Failed to download Piper model files" && exit 1)

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
ENTRYPOINT ["sh", "/scripts/
