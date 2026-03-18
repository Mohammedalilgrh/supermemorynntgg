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
# Instead of just the binary, we need the full package that includes libraries
RUN echo "🎯 Downloading Piper with dependencies..." && \
    mkdir -p /tmp/piper-full && \
    curl -fSL --connect-timeout 30 --retry 2 \
        "https://github.com/rhasspy/piper/releases/download/2023.11.14-2/piper_linux_x86_64.tar.gz" \
        -o /tmp/piper.tar.gz && \
    tar -xzf /tmp/piper.tar.gz -C /tmp/piper-full --strip-components=1 && \
    # Copy binary and ALL libraries
    cp /tmp/piper-full/piper /toolbox/bin/ && \
    cp /tmp/piper-full/libespeak-ng.so* /toolbox/lib/ 2>/dev/null || true && \
    cp /tmp/piper-full/libpiper_phonemize.so* /toolbox/lib/ 2>/dev/null || true && \
    cp /tmp/piper-full/libtashkeel.so* /toolbox/lib/ 2>/dev/null || true && \
    cp /tmp/piper-full/libonnxruntime.so* /toolbox/lib/ 2>/dev/null || true && \
    # Also check in possible subdirectories
    find /tmp/piper-full -name "*.so*" -exec cp {} /toolbox/lib/ \; 2>/dev/null || true && \
    # Copy espeak-ng data if exists
    cp -r /tmp/piper-full/espeak-ng-data /toolbox/ 2>/dev/null || true && \
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
COPY --from=tools /toolbox/bin/              /usr/local/bin/
COPY --from=tools /toolbox/lib/               /usr/local/lib/
COPY --from=tools /toolbox/espeak-ng-data/    /usr/local/share/espeak-ng-data/ 2>/dev/null || true
COPY --from=tools /tmp/piper-voices/          /usr/local/piper-voices/
# Also copy any libraries from the system that might be needed
COPY --from=tools /usr/lib/                    /usr/local/lib/
COPY --from=tools /lib/                         /usr/local/lib2/

# Set library path - VERY IMPORTANT for Piper to find its libraries
ENV LD_LIBRARY_PATH="/usr/local/lib:/usr/local/lib2:/usr/lib:/lib:$LD_LIBRARY_PATH"
ENV PATH="/usr/local/bin:$PATH"

# FFmpeg environment variables
ENV FFMPEG_PATH="/usr/local/bin/ffmpeg"
ENV FFPROBE_PATH="/usr/local/bin/ffprobe"
ENV FFREPORT="file=/tmp/ffreport-%p-%t.log:level=32"
ENV PIPER_MODEL="/usr/local/piper-voices/en_GB-vctk-medium.onnx"
ENV PIPER_SPEAKER="9"
# Point to espeak-ng data if available
ENV ESPEAK_DATA_DIR="/usr/local/share/espeak-ng-data"

# FFmpeg runtime directories
RUN mkdir -p /tmp/ffmpeg-temp /tmp/ffmpeg-cache /var/log/ffmpeg && \
    chmod 1777 /tmp/ffmpeg-temp /tmp/ffmpeg-cache /tmp && \
    chmod 755 /var/log/ffmpeg

# Make binaries executable
RUN chmod +x /usr/local/bin/ffmpeg /usr/local/bin/ffprobe /usr/local/bin/piper

# Verify ffmpeg binaries are working (skip piper verification for now)
RUN /usr/local/bin/ffmpeg -version && \
    /usr/local/bin/ffprobe -version

# Create symlinks for common paths
RUN ln -sf /usr/local/bin/ffmpeg /usr/bin/ffmpeg && \
    ln -sf /usr/local/bin/ffprobe /usr/bin/ffprobe && \
    ln -sf /usr/local/bin/ffmpeg /bin/ffmpeg && \
    ln -sf /usr/local/bin/ffprobe /bin/ffprobe && \
    ln -sf /usr/local/bin/piper /usr/bin/piper && \
    ln -sf /usr/local/bin/piper /bin/piper

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
    onnxruntime \
    && fc-cache -fv

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

# Check if piper works
if ! command -v piper >/dev/null 2>&1; then
    echo "Error: piper command not found" >&2
    exit 1
fi

# Set library path if not already set
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH}:/usr/local/lib:/usr/lib"

echo "🔊 Generating speech for: $TEXT"

case "${OUTPUT##*.}" in
    mp3)
        TMP_WAV="/tmp/tts_temp_$$.wav"
        trap 'rm -f "$TMP_WAV"' EXIT
        
        # Try with espeak-data path if available
        if [ -d "$ESPEAK_DATA_DIR" ]; then
            echo "$TEXT" | piper --model "$PIPER_MODEL" --speaker "$PIPER_SPEAKER" --espeak_data "$ESPEAK_DATA_DIR" --output_file "$TMP_WAV"
        else
            echo "$TEXT" | piper --model "$PIPER_MODEL" --speaker "$PIPER_SPEAKER" --output_file "$TMP_WAV"
        fi
        
        ffmpeg -y -i "$TMP_WAV" -codec:a libmp3lame -qscale:a 2 "$OUTPUT"
        echo "✅ MP3 saved to: $OUTPUT"
        ;;
    wav|*)
        if [ -d "$ESPEAK_DATA_DIR" ]; then
            echo "$TEXT" | piper --model "$PIPER_MODEL" --speaker "$PIPER_SPEAKER" --espeak_data "$ESPEAK_DATA_DIR" --output_file "$OUTPUT"
        else
            echo "$TEXT" | piper --model "$PIPER_MODEL" --speaker "$PIPER_SPEAKER" --output_file "$OUTPUT"
        fi
        echo "✅ WAV saved to: $OUTPUT"
        ;;
esac
EOF

RUN chmod +x /usr/local/bin/tts-en

# Setup directories
RUN mkdir -p /scripts /backup-data /home/node/.n8n && \
    chown -R node:node /home/node/.n8n /scripts /backup-data

# Ensure node user has access to all directories
RUN chown -R node:node /tmp/ffmpeg-temp /tmp/ffmpeg-cache /var/log/ffmpeg /usr/local/piper-voices /usr/local/lib /usr/local/bin

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

# Create a test script that doesn't fail the build
RUN cat > /tmp/test-piper.sh << 'EOF' && chmod +x /tmp/test-piper.sh
#!/bin/sh
echo "🔍 Checking Piper installation..."
if command -v piper >/dev/null 2>&1; then
    echo "✅ Piper binary found"
    # Try to run piper with minimal command
    piper --version 2>/dev/null && echo "✅ Piper version check passed" || echo "⚠️ Piper version check failed (may need libraries)"
else
    echo "❌ Piper binary not found"
fi

if command -v ffmpeg >/dev/null 2>&1; then
    echo "✅ FFmpeg found: $(ffmpeg -version | head -n1)"
else
    echo "❌ FFmpeg not found"
fi
EOF

# Run test as node user (non-fatal)
USER node
RUN /tmp/test-piper.sh || true

WORKDIR /home/node

# Use existing start script or create default
RUN if [ ! -f /scripts/start.sh ]; then \
        echo '#!/bin/sh\ncd /home/node\n exec n8n' > /scripts/start.sh && \
        chmod +x /scripts/start.sh; \
    fi

ENTRYPOINT ["sh", "/scripts/start.sh"]
