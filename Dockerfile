# ==================================================
# STAGE 1: tools (Alpine) — Collect STATIC binaries and libraries
# ==================================================
FROM alpine:3.20 AS tools

RUN apk add --no-cache \
      curl jq sqlite tar gzip xz \
      coreutils findutils ca-certificates && \
    mkdir -p /toolbox/bin /toolbox/lib /toolbox/piper-voices && \
    for cmd in curl jq sqlite3 split sha256sum \
               stat du sort tail awk xargs find \
               wc cut tr gzip tar cat date sleep \
               mkdir rm ls grep sed head touch \
               cp mv basename expr; do \
      p="$(which $cmd 2>/dev/null)" && \
        [ -f "$p" ] && cp "$p" /toolbox/bin/ || true; \
    done

# Download ffmpeg static
RUN curl -L -o /tmp/ffmpeg.tar.xz https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz && \
    tar -xJf /tmp/ffmpeg.tar.xz -C /tmp/ && \
    cp /tmp/ffmpeg-*-static/ffmpeg /toolbox/bin/ && \
    cp /tmp/ffmpeg-*-static/ffprobe /toolbox/bin/ && \
    rm -rf /tmp/ffmpeg-*-static /tmp/ffmpeg.tar.xz

# === Download Piper with ALL dependencies ===
RUN echo "🎯 Downloading Piper with dependencies..." && \
    mkdir -p /tmp/piper-full && \
    curl -fSL --connect-timeout 30 --retry 2 \
        "https://github.com/rhasspy/piper/releases/download/2023.11.14-2/piper_linux_x86_64.tar.gz" \
        -o /tmp/piper.tar.gz && \
    tar -xzf /tmp/piper.tar.gz -C /tmp/piper-full --strip-components=1 && \
    # Copy binary
    cp /tmp/piper-full/piper /toolbox/bin/ && \
    # Copy all shared libraries
    cp /tmp/piper-full/*.so* /toolbox/lib/ 2>/dev/null || true && \
    # Copy espeak-ng data if exists
    if [ -d /tmp/piper-full/espeak-ng-data ]; then \
        cp -r /tmp/piper-full/espeak-ng-data /toolbox/; \
        echo "✅ espeak-ng data copied"; \
    else \
        echo "ℹ️ No espeak-ng data found in Piper package"; \
    fi && \
    rm -rf /tmp/piper* && \
    echo "✅ Piper with libraries ready"

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

# Copy all tools, libraries, and models from stage 1
COPY --from=tools /toolbox/bin/          /usr/local/bin/
COPY --from=tools /toolbox/lib/          /usr/local/lib/
COPY --from=tools /tmp/piper-voices/     /usr/local/piper-voices/

# Copy system libraries from tools stage
COPY --from=tools /usr/lib/              /usr/local/lib/ || true
COPY --from=tools /lib/                  /usr/local/lib2/ || true
COPY --from=tools /etc/ssl/certs/        /etc/ssl/certs/ || true

# Copy espeak-ng data only if it exists (using a more robust method)
RUN if [ -d /toolbox/espeak-ng-data ]; then \
        cp -r /toolbox/espeak-ng-data /usr/local/share/; \
        echo "✅ espeak-ng data copied to final image"; \
    else \
        echo "ℹ️ No espeak-ng data to copy, will use system packages"; \
    fi

# Set library path
ENV LD_LIBRARY_PATH="/usr/local/lib:/usr/local/lib2:/usr/lib:/lib:$LD_LIBRARY_PATH"
ENV PATH="/usr/local/bin:$PATH"

# FFmpeg and Piper environment variables
ENV FFMPEG_PATH="/usr/local/bin/ffmpeg"
ENV FFPROBE_PATH="/usr/local/bin/ffprobe"
ENV FFREPORT="file=/tmp/ffreport-%p-%t.log:level=32"
ENV PIPER_MODEL="/usr/local/piper-voices/en_GB-vctk-medium.onnx"
ENV PIPER_SPEAKER="9"
ENV ESPEAK_DATA_DIR="/usr/local/share/espeak-ng-data"

# Create necessary directories
RUN mkdir -p /tmp/ffmpeg-temp /tmp/ffmpeg-cache /var/log/ffmpeg \
             /scripts /backup-data /home/node/.n8n && \
    chmod 1777 /tmp/ffmpeg-temp /tmp/ffmpeg-cache /tmp && \
    chmod 755 /var/log/ffmpeg

# Make binaries executable
RUN chmod +x /usr/local/bin/ffmpeg /usr/local/bin/ffprobe /usr/local/bin/piper

# Install Alpine dependencies including espeak-ng and onnxruntime
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
    espeak-ng \
    espeak-ng-data \
    onnxruntime \
    && fc-cache -fv

# Create symlinks
RUN ln -sf /usr/local/bin/ffmpeg /usr/bin/ffmpeg 2>/dev/null || true && \
    ln -sf /usr/local/bin/ffprobe /usr/bin/ffprobe 2>/dev/null || true && \
    ln -sf /usr/local/bin/ffmpeg /bin/ffmpeg 2>/dev/null || true && \
    ln -sf /usr/local/bin/ffprobe /bin/ffprobe 2>/dev/null || true && \
    ln -sf /usr/local/bin/piper /usr/bin/piper 2>/dev/null || true && \
    ln -sf /usr/local/bin/piper /bin/piper 2>/dev/null || true

# Create TTS script with better error handling
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

# Set library path
export LD_LIBRARY_PATH="/usr/local/lib:/usr/local/lib2:/usr/lib:/lib:${LD_LIBRARY_PATH}"

echo "🔊 Generating speech for: $TEXT"
echo "📁 Output: $OUTPUT"

# Check if piper exists
if ! command -v piper >/dev/null 2>&1; then
    echo "❌ piper command not found" >&2
    exit 1
fi

# Check if model exists
if [ ! -f "$PIPER_MODEL" ]; then
    echo "❌ Piper model not found at $PIPER_MODEL" >&2
    exit 1
fi

case "${OUTPUT##*.}" in
    mp3)
        TMP_WAV="/tmp/tts_temp_$$.wav"
        trap 'rm -f "$TMP_WAV"' EXIT
        
        echo "🔄 Generating WAV temporarily..."
        echo "$TEXT" | piper \
            --model "$PIPER_MODEL" \
            --speaker "$PIPER_SPEAKER" \
            --output_file "$TMP_WAV"
        
        echo "🔄 Converting to MP3..."
        ffmpeg -y -i "$TMP_WAV" -codec:a libmp3lame -qscale:a 2 "$OUTPUT"
        echo "✅ MP3 saved to: $OUTPUT"
        ;;
    wav|*)
        echo "🔄 Generating WAV directly..."
        echo "$TEXT" | piper \
            --model "$PIPER_MODEL" \
            --speaker "$PIPER_SPEAKER" \
            --output_file "$OUTPUT"
        echo "✅ WAV saved to: $OUTPUT"
        ;;
esac

# Show file size
if [ -f "$OUTPUT" ]; then
    SIZE=$(ls -lh "$OUTPUT" | awk '{print $5}')
    echo "📊 File size: $SIZE"
else
    echo "❌ Output file not created"
    exit 1
fi
EOF

RUN chmod +x /usr/local/bin/tts-en

# Set ownership
RUN chown -R node:node /home/node/.n8n /scripts /backup-data && \
    chown -R node:node /tmp/ffmpeg-temp /tmp/ffmpeg-cache /var/log/ffmpeg && \
    chown -R node:node /usr/local/piper-voices /usr/local/lib /usr/local/bin

# Install Instagram Node (as node user)
USER node
RUN cd /home/node/.n8n && \
    mkdir -p nodes && \
    cd nodes && \
    npm init -y 2>/dev/null || true && \
    npm install @mookielianhd/n8n-nodes-instagram 2>/dev/null || true

# Copy startup scripts
USER root
COPY --chown=node:node scripts/ /scripts/

RUN if [ -d /scripts ]; then \
        find /scripts -type f -name "*.sh" -exec sed -i 's/\r$//' {} \; 2>/dev/null || true; \
        chmod 0755 /scripts/*.sh 2>/dev/null || true; \
    fi

# Verify ffmpeg (non-fatal)
RUN echo "🔍 Verifying FFmpeg..." && \
    ffmpeg -version | head -n1 && \
    echo "✅ FFmpeg OK"

# Test library dependencies
RUN echo "🔍 Checking Piper libraries..." && \
    ldd /usr/local/bin/piper 2>/dev/null | head -10 || true && \
    echo "✅ Library check complete"

WORKDIR /home/node

# Create default start script if none exists
RUN if [ ! -f /scripts/start.sh ]; then \
        echo '#!/bin/sh' > /scripts/start.sh && \
        echo 'cd /home/node' >> /scripts/start.sh && \
        echo 'export LD_LIBRARY_PATH="/usr/local/lib:/usr/local/lib2:/usr/lib:/lib"' >> /scripts/start.sh && \
        echo 'exec n8n' >> /scripts/start.sh && \
        chmod +x /scripts/start.sh; \
    fi

ENTRYPOINT ["sh", "/scripts/start.sh"]
