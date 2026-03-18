# ==================================================
# STAGE 1: tools (Alpine) — Download static binaries
# ==================================================
FROM alpine:3.20 AS tools

RUN apk add --no-cache \
      curl tar gzip xz ca-certificates

RUN mkdir -p /toolbox/bin /toolbox/lib /toolbox/espeak-ng-data /toolbox/piper-voices

# Download FFmpeg static (amd64)
RUN curl -fSL --connect-timeout 60 --retry 3 \
        "https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz" \
        -o /tmp/ffmpeg.tar.xz && \
    tar -xJf /tmp/ffmpeg.tar.xz -C /tmp/ && \
    cp /tmp/ffmpeg-*-static/ffmpeg  /toolbox/bin/ && \
    cp /tmp/ffmpeg-*-static/ffprobe /toolbox/bin/ && \
    rm -rf /tmp/ffmpeg-*-static /tmp/ffmpeg.tar.xz

# Download Piper + libs + espeak-ng-data
RUN mkdir -p /tmp/piper-full && \
    curl -fSL --connect-timeout 60 --retry 3 \
        "https://github.com/rhasspy/piper/releases/download/2023.11.14-2/piper_linux_x86_64.tar.gz" \
        -o /tmp/piper.tar.gz && \
    tar -xzf /tmp/piper.tar.gz -C /tmp/piper-full --strip-components=1 && \
    cp /tmp/piper-full/piper /toolbox/bin/ && \
    find /tmp/piper-full -name "*.so*" -exec cp {} /toolbox/lib/ \; 2>/dev/null || true && \
    if [ -d /tmp/piper-full/espeak-ng-data ]; then \
        cp -r /tmp/piper-full/espeak-ng-data/* /toolbox/espeak-ng-data/; \
    fi && \
    rm -rf /tmp/piper*

# Download Piper voice model
RUN curl -fSL --connect-timeout 60 --retry 3 \
        "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/vctk/medium/en_GB-vctk-medium.onnx" \
        -o /toolbox/piper-voices/en_GB-vctk-medium.onnx && \
    curl -fSL --connect-timeout 60 --retry 3 \
        "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/vctk/medium/en_GB-vctk-medium.onnx.json" \
        -o /toolbox/piper-voices/en_GB-vctk-medium.onnx.json

# ==================================================
# STAGE 2: n8n final image (Alpine-based)
# ==================================================
FROM docker.n8n.io/n8nio/n8n:2.6.2

USER root

# --- Copy binaries and data from stage 1 ---
COPY --from=tools /toolbox/bin/            /usr/local/bin/
COPY --from=tools /toolbox/lib/            /usr/local/lib/piper/
COPY --from=tools /toolbox/piper-voices/   /usr/local/piper-voices/
COPY --from=tools /toolbox/espeak-ng-data/ /usr/local/share/espeak-ng-data/
COPY --from=tools /etc/ssl/certs/          /etc/ssl/certs/

# --- Environment ---
ENV LD_LIBRARY_PATH="/usr/local/lib/piper:/usr/lib:/lib"
ENV PATH="/usr/local/bin:$PATH"
ENV FFMPEG_PATH="/usr/local/bin/ffmpeg"
ENV FFPROBE_PATH="/usr/local/bin/ffprobe"
ENV FFREPORT="file=/tmp/ffreport-%p-%t.log:level=32"
ENV PIPER_MODEL="/usr/local/piper-voices/en_GB-vctk-medium.onnx"
ENV PIPER_SPEAKER="9"
ENV ESPEAK_DATA_PATH="/usr/local/share/espeak-ng-data"

# --- Alpine packages (apk only — no onnxruntime, included in piper binary) ---
RUN /sbin/apk add --no-cache \
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
    sqlite \
    jq \
    curl \
    ca-certificates \
    && fc-cache -fv \
    && echo "Alpine packages installed"

# --- Make binaries executable + symlinks ---
RUN chmod +x \
        /usr/local/bin/ffmpeg \
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
[ -z "$TEXT" ] && { echo "Error: No text provided" >&2; exit 1; }
mkdir -p "$(dirname "$OUTPUT")"
export LD_LIBRARY_PATH="/usr/local/lib/piper:/usr/lib:/lib:${LD_LIBRARY_PATH:-}"
command -v piper >/dev/null 2>&1 || { echo "piper not found" >&2; exit 1; }
[ -f "$PIPER_MODEL" ] || { echo "Model not found: $PIPER_MODEL" >&2; exit 1; }
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
[ -s "$OUTPUT" ] \
    && echo "Done: $OUTPUT ($(du -h "$OUTPUT" | cut -f1))" \
    || { echo "Output file empty or missing" >&2; exit 1; }
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

# --- Final verification ---
RUN ffmpeg -version | head -n1 && \
    test -x /usr/local/bin/piper   && echo "piper OK" && \
    test -x /usr/local/bin/tts-en  && echo "tts-en OK" && \
    test -f /usr/local/piper-voices/en_GB-vctk-medium.onnx && echo "model OK" && \
    echo "All checks passed"

WORKDIR /home/node
ENTRYPOINT ["sh", "/scripts/start.sh"]
