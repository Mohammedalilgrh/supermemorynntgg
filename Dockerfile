# ==================================================
# STAGE 1: tools (Alpine) — Collect STATIC binaries
# ==================================================
FROM alpine:3.20 AS tools

RUN apk add --no-cache \
      curl jq sqlite tar gzip xz \
      coreutils findutils ca-certificates

RUN mkdir -p /toolbox/bin /toolbox/lib /toolbox/espeak-ng-data /toolbox/piper-voices

# Copy useful shell tools
RUN for cmd in curl jq sqlite3 split sha256sum \
               stat du sort tail awk xargs find \
               wc cut tr gzip tar cat date sleep \
               mkdir rm ls grep sed head touch \
               cp mv basename expr; do \
      p="$(which $cmd 2>/dev/null)" && \
        [ -f "$p" ] && cp "$p" /toolbox/bin/ || true; \
    done

# Download FFmpeg static (amd64)
RUN echo "⬇️ Downloading FFmpeg..." && \
    curl -fSL --connect-timeout 60 --retry 3 \
        "https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz" \
        -o /tmp/ffmpeg.tar.xz && \
    tar -xJf /tmp/ffmpeg.tar.xz -C /tmp/ && \
    cp /tmp/ffmpeg-*-static/ffmpeg  /toolbox/bin/ && \
    cp /tmp/ffmpeg-*-static/ffprobe /toolbox/bin/ && \
    rm -rf /tmp/ffmpeg-*-static /tmp/ffmpeg.tar.xz && \
    echo "✅ FFmpeg ready"

# Download Piper + libs + espeak-ng-data
RUN echo "⬇️ Downloading Piper..." && \
    mkdir -p /tmp/piper-full && \
    curl -fSL --connect-timeout 60 --retry 3 \
        "https://github.com/rhasspy/piper/releases/download/2023.11.14-2/piper_linux_x86_64.tar.gz" \
        -o /tmp/piper.tar.gz && \
    tar -xzf /tmp/piper.tar.gz -C /tmp/piper-full --strip-components=1 && \
    cp /tmp/piper-full/piper /toolbox/bin/ && \
    find /tmp/piper-full -name "*.so*" -exec cp {} /toolbox/lib/ \; 2>/dev/null || true && \
    if [ -d /tmp/piper-full/espeak-ng-data ]; then \
        cp -r /tmp/piper-full/espeak-ng-data/* /toolbox/espeak-ng-data/; \
        echo "✅ espeak-ng-data copied"; \
    else \
        echo "ℹ️ No espeak-ng-data in package"; \
    fi && \
    rm -rf /tmp/piper* && \
    echo "✅ Piper ready"

# Download Piper voice model
RUN echo "⬇️ Downloading voice model..." && \
    curl -fSL --connect-timeout 60 --retry 3 \
        "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/vctk/medium/en_GB-vctk-medium.onnx" \
        -o /toolbox/piper-voices/en_GB-vctk-medium.onnx && \
    curl -fSL --connect-timeout 60 --retry 3 \
        "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/vctk/medium/en_GB-vctk-medium.onnx.json" \
        -o /toolbox/piper-voices/en_GB-vctk-medium.onnx.json && \
    echo "✅ Voice model ready"

# ==================================================
# STAGE 2: n8n final image
# ==================================================
FROM docker.n8n.io/n8nio/n8n:2.6.2-debian

USER root

# --- Copy binaries and data from stage 1 ---
COPY --from=tools /toolbox/bin/          /usr/local/bin/
COPY --from=tools /toolbox/lib/          /usr/local/lib/piper/
COPY --from=tools /toolbox/piper-voices/ /usr/local/piper-voices/
COPY --from=tools /toolbox/espeak-ng-data/ /usr/local/share/espeak-ng-data/
COPY --from=tools /etc/ssl/certs/        /etc/ssl/certs/

# --- Environment ---
ENV LD_LIBRARY_PATH="/usr/local/lib/piper:/usr/lib:/lib"
ENV PATH="/usr/local/bin:$PATH"
ENV FFMPEG_PATH="/usr/local/bin/ffmpeg"
ENV FFPROBE_PATH="/usr/local/bin/ffprobe"
ENV FFREPORT="file=/tmp/ffreport-%p-%t.log:level=32"
ENV PIPER_MODEL="/usr/local/piper-voices/en_GB-vctk-medium.onnx"
ENV PIPER_SPEAKER="9"
ENV ESPEAK_DATA_PATH="/usr/local/share/espeak-ng-data"

# --- Alpine packages ---
RUN apk add --no-cache \
    fontconfig \
    ttf-dejavu \
    font-noto \
    font-noto-arabic \
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
    sqlite \
    jq \
    curl \
    && fc-cache -fv \
    && echo "✅ Alpine packages installed"

# --- Make binaries executable + symlinks ---
RUN chmod +x /usr/local/bin/ffmpeg \
              /usr/local/bin/ffprobe \
              /usr/local/bin/piper && \
    ln -sf /usr/local/bin/ffmpeg  /usr/bin/ffmpeg  && \
    ln -sf /usr/local/bin/ffprobe /usr/bin/ffprobe && \
    ln -sf /usr/local/bin/piper   /usr/bin/piper

# --- Create directories ---
RUN mkdir -p \
    /tmp/ffmpeg-temp \
    /tmp/ffmpeg-cache \
    /var/log/ffmpeg \
    /scripts \
    /backup-data \
    /home/node/.n8n && \
    chmod 1777 /tmp && \
    chmod 755 /var/log/ffmpeg

# --- TTS script ---
RUN cat > /usr/local/bin/tts-en << 'TTSEOF'
#!/bin/sh
set -e

TEXT="$1"
OUTPUT="${2:-/tmp/tts_out.wav}"

[ -z "$TEXT" ] && { echo "❌ Error: No text provided" >&2; exit 1; }

mkdir -p "$(dirname "$OUTPUT")"

export LD_LIBRARY_PATH="/usr/local/lib/piper:/usr/lib:/lib:${LD_LIBRARY_PATH:-}"

command -v piper >/dev/null 2>&1 || { echo "❌ piper not found" >&2; exit 1; }
[ -f "$PIPER_MODEL" ] || { echo "❌ Model not found: $PIPER_MODEL" >&2; exit 1; }

case "${OUTPUT##*.}" in
    mp3)
        TMP_WAV="/tmp/tts_$$_tmp.wav"
        trap 'rm -f "$TMP_WAV"' EXIT
        echo "$TEXT" | piper \
            --model "$PIPER_MODEL" \
            --speaker "$PIPER_SPEAKER" \
            --output_file "$TMP_WAV"
        ffmpeg -y -hide_banner -loglevel error \
            -i "$TMP_WAV" \
            -codec:a libmp3lame -qscale:a 2 \
            "$OUTPUT"
        ;;
    *)
        echo "$TEXT" | piper \
            --model "$PIPER_MODEL" \
            --speaker "$PIPER_SPEAKER" \
            --output_file "$OUTPUT"
        ;;
esac

[ -s "$OUTPUT" ] && echo "✅ Done: $OUTPUT ($(du -h "$OUTPUT" | cut -f1))" || { echo "❌ Output empty" >&2; exit 1; }
TTSEOF

RUN chmod +x /usr/local/bin/tts-en

# --- Ownership ---
RUN chown -R node:node \
    /home/node/.n8n \
    /scripts \
    /backup-data \
    /tmp/ffmpeg-temp \
    /tmp/ffmpeg-cache \
    /var/log/ffmpeg \
    /usr/local/piper-voices

# --- Install Instagram node ---
USER node
RUN mkdir -p /home/node/.n8n/nodes && \
    cd /home/node/.n8n/nodes && \
    npm init -y 2>/dev/null || true && \
    npm install @mookielianhd/n8n-nodes-instagram 2>/dev/null || true

# --- Copy scripts ---
USER root
COPY --chown=node:node scripts/ /scripts/

RUN find /scripts -type f -name "*.sh" \
        -exec sed -i 's/\r$//' {} \; 2>/dev/null || true && \
    chmod 0755 /scripts/*.sh 2>/dev/null || true

# --- Verify builds ---
RUN echo "=== Verify FFmpeg ===" && \
    ffmpeg -version | head -n1 && \
    echo "=== Verify Piper ===" && \
    piper --help 2>&1 | head -n2 || true && \
    echo "=== Verify TTS script ===" && \
    test -x /usr/local/bin/tts-en && echo "✅ tts-en OK" && \
    echo "=== All checks passed ==="

WORKDIR /home/node
ENTRYPOINT ["sh", "/scripts/start.sh"]
