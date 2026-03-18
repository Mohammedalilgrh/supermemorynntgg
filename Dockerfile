FROM docker.n8n.io/n8nio/n8n:2.6.2

USER root

# Install Debian dependencies
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
    curl ca-certificates tar xz-utils \
    fontconfig fonts-dejavu fonts-noto fonts-noto-core fonts-noto-color-emoji \
    libass9 libfribidi0 libharfbuzz0b libfreetype6 libfontconfig1 \
    libstdc++6 zlib1g libexpat1 libgomp1 \
    && rm -rf /var/lib/apt/lists/* && \
    fc-cache -fv

# === Download Static FFmpeg (best version for Docker) ===
RUN curl -L -o /tmp/ffmpeg.tar.xz https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz && \
    mkdir -p /tmp/ffmpeg && \
    tar -xJf /tmp/ffmpeg.tar.xz -C /tmp/ffmpeg --strip-components=1 && \
    cp /tmp/ffmpeg/ffmpeg /usr/local/bin/ && \
    cp /tmp/ffmpeg/ffprobe /usr/local/bin/ && \
    chmod +x /usr/local/bin/ffmpeg /usr/local/bin/ffprobe && \
    rm -rf /tmp/ffmpeg*

# === Download Piper + British Voice ===
RUN curl -L -o /tmp/piper.tar.gz \
    "https://github.com/rhasspy/piper/releases/download/2023.11.14-2/piper_linux_x86_64.tar.gz" && \
    mkdir -p /usr/local/piper && \
    tar -xzf /tmp/piper.tar.gz -C /usr/local/piper --strip-components=1 && \
    rm -f /tmp/piper.tar.gz

RUN mkdir -p /usr/local/piper-voices && \
    curl -L -o /usr/local/piper-voices/en_GB-vctk-medium.onnx \
      "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/vctk/medium/en_GB-vctk-medium.onnx" && \
    curl -L -o /usr/local/piper-voices/en_GB-vctk-medium.onnx.json \
      "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/vctk/medium/en_GB-vctk-medium.onnx.json"

# === Environment ===
ENV PATH="/usr/local/bin:/usr/local/piper:$PATH" \
    LD_LIBRARY_PATH="/usr/local/piper:$LD_LIBRARY_PATH" \
    FFMPEG_PATH="/usr/local/bin/ffmpeg" \
    FFPROBE_PATH="/usr/local/bin/ffprobe" \
    PIPER_MODEL="/usr/local/piper-voices/en_GB-vctk-medium.onnx" \
    PIPER_SPEAKER="9" \
    FFREPORT="file=/tmp/ffreport-%p-%t.log:level=32"

# Create directories with correct permissions
RUN mkdir -p /tmp/ffmpeg-temp /tmp/ffmpeg-cache /var/log/ffmpeg /scripts /backup-data /home/node/.n8n && \
    chmod 1777 /tmp /tmp/ffmpeg-temp /tmp/ffmpeg-cache && \
    chmod 755 /var/log/ffmpeg

# Symlinks + permissions
RUN chmod +x /usr/local/piper/piper && \
    ln -sf /usr/local/bin/ffmpeg /usr/bin/ffmpeg && \
    ln -sf /usr/local/bin/ffprobe /usr/bin/ffprobe && \
    ln -sf /usr/local/piper/piper /usr/local/bin/piper

# === Improved TTS Script ===
RUN cat > /usr/local/bin/tts-en << 'EOF'
#!/bin/sh
set -e
TEXT="$1"
OUTPUT="${2:-/tmp/tts_out.wav}"

if [ -z "$TEXT" ]; then
  echo "Error: No text provided" >&2
  exit 1
fi

case "$OUTPUT" in
  *.mp3)
    TMP_WAV="/tmp/_piper_$$.wav"
    echo "$TEXT" | piper --model "$PIPER_MODEL" --speaker "$PIPER_SPEAKER" --output_file "$TMP_WAV"
    ffmpeg -y -i "$TMP_WAV" -codec:a libmp3lame -qscale:a 2 "$OUTPUT"
    rm -f "$TMP_WAV"
    ;;
  *)
    echo "$TEXT" | piper --model "$PIPER_MODEL" --speaker "$PIPER_SPEAKER" --output_file "$OUTPUT"
    ;;
esac
echo "✅ TTS done: $OUTPUT"
EOF

RUN chmod +x /usr/local/bin/tts-en

# Install community node
USER node
RUN cd /home/node/.n8n && mkdir -p nodes && cd nodes && \
    npm init -y && npm install @mookielianhd/n8n-nodes-instagram

USER root

COPY --chown=node:node scripts/ /scripts/
RUN sed -i 's/\r$//' /scripts/*.sh 2>/dev/null || true && \
    chmod +x /scripts/*.sh

# Final test
USER node
RUN ffmpeg -version && ffprobe -version && \
    echo "Hello from Piper" | piper --model "$PIPER_MODEL" --speaker "$PIPER_SPEAKER" --output_file /tmp/test.wav && \
    ls -lh /tmp/test.wav && \
    echo "✅ Build completed successfully - FFmpeg & Piper ready"

WORKDIR /home/node
ENTRYPOINT ["sh", "/scripts/start.sh"]
