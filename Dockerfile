# ==================================================
# STAGE 1: tools (Alpine) — Collect STATIC binaries and Piper
# ==================================================
FROM alpine:3.20 AS tools

RUN apk add --no-cache \
      curl jq sqlite tar gzip xz \
      coreutils findutils ca-certificates && \
    mkdir -p /toolbox && \
    for cmd in curl jq sqlite3 split sha256sum \
               stat du sort tail awk xargs find \
               wc cut tr gzip tar cat date sleep \
               mkdir rm ls grep sed head touch \
               cp mv basename expr; do \
      p="$(which $cmd 2>/dev/null)" && \
        [ -f "$p" ] && cp "$p" /toolbox/ || true; \
    done

# Download ffmpeg static
RUN curl -L -o /tmp/ffmpeg.tar.xz https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz && \
    tar -xJf /tmp/ffmpeg.tar.xz -C /tmp/ && \
    cp /tmp/ffmpeg-*-static/ffmpeg /toolbox/ && \
    cp /tmp/ffmpeg-*-static/ffprobe /toolbox/ && \
    rm -rf /tmp/ffmpeg-*-static /tmp/ffmpeg.tar.xz

# === Download Piper (static binary) ===
RUN echo "🎯 Downloading Piper..." && \
    curl -fSL --connect-timeout 30 --retry 2 \
        "https://github.com/rhasspy/piper/releases/download/2023.11.14-2/piper_linux_x86_64.tar.gz" \
        -o /tmp/piper.tar.gz && \
    tar -xzf /tmp/piper.tar.gz -C /tmp/ && \
    cp /tmp/piper/piper /toolbox/ && \
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
# STAGE 2: n8n (Alpine-based) — Final runtime
# ==================================================
FROM docker.n8n.io/n8nio/n8n:2.6.2

USER root

# Copy all tools and libraries from stage 1
COPY --from=tools /toolbox/              /usr/local/bin/
COPY --from=tools /usr/lib/              /usr/local/lib/
COPY --from=tools /lib/                   /usr/local/lib2/
COPY --from=tools /etc/ssl/certs/         /etc/ssl/certs/
COPY --from=tools /tmp/piper-voices/      /usr/local/piper-voices/

# Set library path
ENV LD_LIBRARY_PATH="/usr/local/lib:/usr/local/lib2:$LD_LIBRARY_PATH"
ENV PATH="/usr/local/bin:$PATH"

# FFmpeg environment variables
ENV FFMPEG_PATH="/usr/local/bin/ffmpeg"
ENV FFPROBE_PATH="/usr/local/bin/ffprobe"
ENV FFREPORT="file=/tmp/ffreport-%p-%t.log:level=32"
ENV PIPER_MODEL="/usr/local/piper-voices/en_GB-vctk-medium.onnx"
ENV PIPER_SPEAKER="9"

# FFmpeg runtime directories
RUN mkdir -p /tmp/ffmpeg-temp /tmp/ffmpeg-cache /var/log/ffmpeg && \
    chmod 1777 /tmp/ffmpeg-temp /tmp/ffmpeg-cache /tmp && \
    chmod 755 /var/log/ffmpeg

# Make binaries executable
RUN chmod +x /usr/local/bin/ffmpeg /usr/local/bin/ffprobe /usr/local/bin/piper

# Verify ffmpeg binaries are working
RUN /usr/local/bin/ffmpeg -version && \
    /usr/local/bin/ffprobe -version && \
    /usr/local/bin/piper --version

# Create symlinks for common paths
RUN ln -sf /usr/local/bin/ffmpeg /usr/bin/ffmpeg && \
    ln -sf /usr/local/bin/ffprobe /usr/bin/ffprobe && \
    ln -sf /usr/local/bin/ffmpeg /bin/ffmpeg && \
    ln -sf /usr/local/bin/ffprobe /bin/ffprobe && \
    ln -sf /usr/local/bin/piper /usr/bin/piper && \
    ln -sf /usr/local/bin/piper /bin/piper

# Install Alpine dependencies (fonts and libraries)
RUN apk add --no-cache \
    fontconfig \
    ttf-dejavu \
    font-noto \
    font-noto-arabic \
    font-noto-extra \
    libass \
    fribidi \
    harfbuzz \
    freetype \
    libstdc++ \
    libgcc \
    libgomp \
    zlib \
    expat \
    && fc-cache -fv

# Create TTS script
RUN cat > /usr/local/bin/tts-en << 'EOF'
#!/bin/sh
set -e
TEXT="$1"
OUTPUT="${2:-/tmp/tts_out.wav}"

if [ -z "$TEXT" ]; then
    echo "Error: No text provided" >&2
    exit 1
fi

mkdir -p "$(dirname "$OUTPUT")"

case "${OUTPUT##*.}" in
    mp3)
        TMP_WAV="/tmp/tts_temp_$$.wav"
        trap 'rm -f "$TMP_WAV"' EXIT
        
        echo "$TEXT" | piper --model "$PIPER_MODEL" --speaker "$PIPER_SPEAKER" --output_file "$TMP_WAV"
        ffmpeg -y -i "$TMP_WAV" -codec:a libmp3lame -qscale:a 2 "$OUTPUT"
        echo "✅ MP3 saved to: $OUTPUT"
        ;;
    wav|*)
        echo "$TEXT" | piper --model "$PIPER_MODEL" --speaker "$PIPER_SPEAKER" --output_file "$OUTPUT"
        echo "✅ WAV saved to: $OUTPUT"
        ;;
esac
EOF

RUN chmod +x /usr/local/bin/tts-en

# Setup directories
RUN mkdir -p /scripts /backup-data /home/node/.n8n && \
    chown -R node:node /home/node/.n8n /scripts /backup-data

# Ensure node user has access to ffmpeg temp directories
RUN chown -R node:node /tmp/ffmpeg-temp /tmp/ffmpeg-cache /var/log/ffmpeg /usr/local/piper-voices

# Install Instagram Node (as node user)
USER node
RUN cd /home/node/.n8n && \
    mkdir -p nodes && \
    cd nodes && \
    npm init -y 2>/dev/null && \
    npm install @mookielianhd/n8n-nodes-instagram 2>/dev/null || true

# Copy startup scripts
USER root
COPY --chown=node:node scripts/ /scripts/

RUN if [ -d /scripts ]; then \
        sed -i 's/\r$//' /scripts/*.sh 2>/dev/null || true && \
        chmod 0755 /scripts/*.sh 2>/dev/null || true; \
    fi

# Final verification
USER node
RUN echo "🔍 Verifying installations..." && \
    ffmpeg -version | head -n1 && \
    ffprobe -version | head -n1 && \
    piper --version && \
    echo "🎯 Testing TTS..." && \
    tts-en "Hello from Piper TTS in n8n!" /tmp/test_tts.wav && \
    if [ -f /tmp/test_tts.wav ]; then \
        echo "✅ TTS test passed - file size: $(stat -c%s /tmp/test_tts.wav 2>/dev/null || stat -f%z /tmp/test_tts.wav 2>/dev/null) bytes"; \
    else \
        echo "⚠️ TTS test warning"; \
    fi && \
    fc-list :lang=ar 2>/dev/null | head -5 || echo "Arabic fonts check done"

WORKDIR /home/node

# Use existing start script or create default
RUN if [ ! -f /scripts/start.sh ]; then \
        echo '#!/bin/sh\ncd /home/node\n exec n8n' > /scripts/start.sh && \
        chmod +x /scripts/start.sh; \
    fi

ENTRYPOINT ["sh", "/scripts/start.sh"]
