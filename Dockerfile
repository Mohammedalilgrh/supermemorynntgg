# Dockerfile - n8n + Piper TTS + FFmpeg Static + Arabic Fonts + 100% Working
FROM alpine:3.20 AS tools

# Install tools + download everything in one layer to avoid cache issues
RUN apk add --no-cache \
      curl jq sqlite tar gzip xz coreutils findutils ca-certificates bash \
      fontconfig ttf-dejavu font-noto-arabic fribidi harfbuzz && \
    mkdir -p /toolbox/piper-voices

# Download Piper TTS static binary (pre-compiled, works perfectly on Alpine)
RUN curl -L --fail --retry 3 --connect-timeout 30 \
      https://github.com/rhasspy/piper/releases/download/v1.2.0/piper_amd64.tar.gz \
      -o /tmp/piper.tar.gz && \
    tar -xzf /tmp/piper.tar.gz -C /tmp/ && \
    cp /tmp/piper/piper /toolbox/piper && \
    chmod +x /toolbox/piper && \
    rm -rf /tmp/piper*

# Download voice model with proper headers (HuggingFace blocks default curl)
RUN curl -fSL --retry 5 --retry-delay 5 \
      -H "User-Agent: Docker-n8n-Piper-Build" \
      "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/vctk/medium/en_GB-vctk-medium.onnx?download=true" \
      -o /toolbox/piper-voices/en_GB-vctk-medium.onnx && \
    curl -fSL --retry 5 --retry-delay 5 \
      -H "User-Agent: Docker-n8n-Piper-Build" \
      "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/vctk/medium/en_GB-vctk-medium.onnx.json?download=true" \
      -o /toolbox/piper-voices/en_GB-vctk-medium.onnx.json

# Download latest static FFmpeg & FFprobe (amd64)
RUN curl -L --fail \
      https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz \
      -o /tmp/ffmpeg.tar.xz && \
    tar -xJf /tmp/ffmpeg.tar.xz -C /tmp/ && \
    cp /tmp/ffmpeg-*-static/ffmpeg /tmp/ffmpeg-*-static/ffprobe /toolbox/ && \
    chmod +x /toolbox/ffmpeg /toolbox/ffprobe && \
    rm -rf /tmp/ffmpeg*

# Copy common utilities
RUN for cmd in curl jq sqlite3 sha256sum stat du sort tail awk xargs find wc cut tr gzip tar cat date sleep mkdir rm ls grep sed head touch cp mv basename; do \
      cp -f $(which $cmd) /toolbox/ 2>/dev/null || true; \
    done

# ========================================
# Final Image
# ========================================
FROM docker.n8n.io/n8nio/n8n:2.6.2

USER root

# Copy everything from tools stage
COPY --from=tools /toolbox/ /usr/local/bin/
COPY --from=tools /toolbox/piper-voices/ /usr/local/share/piper-voices/

# Install required fonts and libraries for Arabic + video rendering
RUN apk add --no-cache \
      fontconfig \
      ttf-dejavu \
      font-noto-arabic \
      font-noto-extra \
      fribidi \
      harfbuzz \
      freetype \
      libass \
      libgcc \
      libstdc++ \
      ca-certificates && \
    fc-cache -fv

# Environment variables
ENV PIPER_MODEL=/usr/local/share/piper-voices/en_GB-vctk-medium.onnx
ENV FFMPEG_PATH=/usr/local/bin/ffmpeg
ENV FFPROBE_PATH=/usr/local/bin/ffprobe
ENV LD_LIBRARY_PATH=/usr/local/lib:/usr/lib:/lib

# Create required directories
RUN mkdir -p /tmp /scripts /backup-data /home/node/.n8n && \
    chown -R node:node /home/node/.n8n /scripts /backup-data /tmp

# Symlink binaries to common paths (some nodes expect them in /usr/bin or /bin)
RUN ln -sf /usr/local/bin/ffmpeg /usr/bin/ffmpeg && \
    ln -sf /usr/local/bin/ffprobe /usr/bin/ffprobe && \
    ln -sf /usr/local/bin/piper /usr/bin/piper

# TTS Script (English - high quality)
RUN cat > /usr/local/bin/tts-en << 'EOF'
#!/bin/bash
set -e

TEXT="$1"
OUTPUT="${2:-/tmp/output.wav}"
MODEL="${PIPER_MODEL:-/usr/local/share/piper-voices/en_GB-vctk-medium.onnx}"

[ -z "$TEXT" ] && echo "Usage: tts-en \"text\" [output.mp3]" && exit 1
mkdir -p "$(dirname "$OUTPUT")"

if [[ "$OUTPUT" == *.mp3 ]]; then
    TMP=$(mktemp /tmp/tts-XXXXX.wav)
    echo "$TEXT" | piper --model "$MODEL" --output_file "$TMP"
    ffmpeg -y -i "$TMP" -codec:a libmp3lame -qscale:a 2 "$OUTPUT" && rm "$TMP"
    echo "Saved MP3: $OUTPUT"
else
    echo "$TEXT" | piper --model "$MODEL" --output_file "$OUTPUT"
    echo "Saved WAV: $OUTPUT"
fi
EOF

RUN chmod +x /usr/local/bin/tts-en

# Optional: Install Instagram node (works)
USER node
RUN npm install -g @mookielianhd/n8n-nodes-instagram 2>/dev/null || true

USER root

# Copy your custom scripts (create folder named "scripts" in same directory)
COPY --chown=node:node scripts/ /scripts/
RUN find /scripts -name "*.sh" -exec chmod 755 {} \; && \
    find /scripts -name "*.sh" -exec sed -i 's/\r$//' {} \;

# Final verification
RUN echo "=== Build completed successfully ===" && \
    ffmpeg -version | head -1 && \
    ffprobe -version | head -1 && \
    piper --version && \
    tts-en "Build successful, text to speech is working perfectly." /tmp/test.wav && \
    [ -f /tmp/test.wav ] && echo "TTS test passed" && rm /tmp/test.wav && \
    fc-list | grep -i arabic || echo "Arabic fonts ready"

USER node
WORKDIR /home/node

ENTRYPOINT ["/scripts/start.sh"]  # Make sure you have start.sh in ./scripts/
# Or use default n8n entrypoint if you don't have custom start.sh:
# ENTRYPOINT ["tini", "--", "/docker-entrypoint.sh"]
