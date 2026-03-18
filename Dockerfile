FROM docker.n8n.io/n8nio/n8n:2.6.2

USER root

# Install Debian-compatible system dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl jq sqlite3 coreutils findutils ca-certificates \
    fontconfig fonts-dejavu fonts-noto fonts-noto-core fonts-noto-arabic \
    libass9 libfribidi0 libharfbuzz0b libfreetype6 libstdc++6 zlib1g libexpat1 \
    && rm -rf /var/lib/apt/lists/*

# Create required directories with proper permissions
RUN mkdir -p /usr/local/piper /usr/local/piper-voices \
    /tmp/ffmpeg-temp /tmp/ffmpeg-cache /var/log/ffmpeg \
    /scripts /backup-data /home/node/.n8n/nodes \
    && chown -R node:node /home/node/.n8n /scripts /backup-data \
    && chmod 1777 /tmp/ffmpeg-temp /tmp/ffmpeg-cache /tmp \
    && chmod 755 /var/log/ffmpeg

# Download static FFmpeg (works on Debian without extra libs)
RUN curl -L -o /tmp/ffmpeg.tar.xz https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz \
    && tar -xJf /tmp/ffmpeg.tar.xz -C /tmp --strip-components=1 \
    && cp /tmp/ffmpeg /tmp/ffprobe /usr/local/bin/ \
    && chmod +x /usr/local/bin/ffmpeg /usr/local/bin/ffprobe \
    && rm -rf /tmp/ffmpeg*

# Download Piper static binary
RUN curl -L -o /tmp/piper.tar.gz https://github.com/rhasspy/piper/releases/download/2023.11.14-2/piper_linux_x86_64.tar.gz \
    && tar -xzf /tmp/piper.tar.gz -C /usr/local/piper --strip-components=1 \
    && chmod +x /usr/local/piper/piper \
    && ln -sf /usr/local/piper/piper /usr/local/bin/piper \
    && rm /tmp/piper.tar.gz

# Download Piper British English model
RUN curl -L -o /usr/local/piper-voices/en_GB-vctk-medium.onnx \
    https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/vctk/medium/en_GB-vctk-medium.onnx \
    && curl -L -o /usr/local/piper-voices/en_GB-vctk-medium.onnx.json \
    https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/vctk/medium/en_GB-vctk-medium.onnx.json

# Environment Variables
ENV LD_LIBRARY_PATH="/usr/local/lib:/usr/local/piper:$LD_LIBRARY_PATH"
ENV PATH="/usr/local/bin:/usr/local/piper:$PATH"

# FFmpeg Config
ENV FFMPEG_PATH="/usr/local/bin/ffmpeg"
ENV FFPROBE_PATH="/usr/local/bin/ffprobe"
ENV FFREPORT="file=/tmp/ffreport-%p-%t.log:level=32"

# Piper Config
ENV PIPER_MODEL="/usr/local/piper-voices/en_GB-vctk-medium.onnx"
ENV PIPER_SPEAKER="9"

# FFmpeg Symlinks (for broad compatibility)
RUN ln -sf /usr/local/bin/ffmpeg /usr/bin/ffmpeg \
    && ln -sf /usr/local/bin/ffprobe /usr/bin/ffprobe \
    && ln -sf /usr/local/bin/ffmpeg /bin/ffmpeg \
    && ln -sf /usr/local/bin/ffprobe /bin/ffprobe

# Update font cache for text rendering
RUN fc-cache -fv

# Robust TTS Script with error handling
RUN cat > /usr/local/bin/tts-en << 'EOF'
#!/bin/bash
set -euo pipefail

# Validate input
if [ -z "${1:-}" ]; then
    echo "Error: No text provided"
    exit 1
fi

TEXT="$1"
OUTPUT="${2:-/tmp/tts_out.wav}"
mkdir -p $(dirname "$OUTPUT")

case "$OUTPUT" in
    *.mp3)
        TMP_WAV=$(mktemp /tmp/piper_XXXXXX.wav)
        trap 'rm -f "$TMP_WAV"' EXIT
        echo "$TEXT" | piper --model "$PIPER_MODEL" --speaker "$PIPER_SPEAKER" --output_file "$TMP_WAV"
        ffmpeg -y -hide_banner -loglevel error -i "$TMP_WAV" -codec:a libmp3lame -qscale:a 2 "$OUTPUT"
        echo "Success: MP3 saved to $OUTPUT"
        ;;
    *)
        echo "$TEXT" | piper --model "$PIPER_MODEL" --speaker "$PIPER_SPEAKER" --output_file "$OUTPUT"
        echo "Success: WAV saved to $OUTPUT"
        ;;
esac
EOF

RUN chmod +x /usr/local/bin/tts-en

# Install n8n Instagram Node
USER node
RUN cd /home/node/.n8n/nodes \
    && npm init -y --silent \
    && npm install @mookielianhd/n8n-nodes-instagram --silent || true

# Setup Custom Start Script
USER root
COPY --chown=node:node scripts/ /scripts/
RUN sed -i 's/\r$//' /scripts/*.sh \
    && chmod 0755 /scripts/*.sh

# Final Verification (ensures all tools work)
USER node
RUN echo "=== Verifying FFmpeg ===" \
    && ffmpeg -version \
    && ffprobe -version \
    && echo "=== Verifying Piper ===" \
    && piper --version \
    && echo "Testing TTS..." \
    && tts-en "Hello! This is a working test of Piper TTS on n8n." /tmp/test_tts.mp3 \
    && ls -lh /tmp/test_tts.mp3 \
    && echo "=== All Tests Passed! ==="

WORKDIR /home/node
ENTRYPOINT ["sh", "/scripts/start.sh"]
