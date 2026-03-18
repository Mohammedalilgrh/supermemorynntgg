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
# Download Piper voice model
RUN curl -fSL --connect-timeout 60 --retry 3 \
        "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/vctk/medium/en_GB-vctk-medium.onnx" \
        -o /toolbox/piper-voices/en_GB-vctk-medium.onnx && \
    curl -fSL --connect-timeout 60 --retry 3 \
        "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/vctk/medium/en_GB-vctk-medium.onnx.json" \
        -o /toolbox/piper-voices/en_GB-vctk-medium.onnx.json
# تحميل ffmpeg static في مرحلة Alpine
RUN curl -L -o /tmp/ffmpeg.tar.xz https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz && \
    tar -xJf /tmp/ffmpeg.tar.xz -C /tmp/ && \
    cp /tmp/ffmpeg-*-static/ffmpeg /toolbox/ && \
    cp /tmp/ffmpeg-*-static/ffprobe /toolbox/ && \
    rm -rf /tmp/ffmpeg-*-static /tmp/ffmpeg.tar.xz

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

COPY --from=tools /toolbox/        /usr/local/bin/
COPY --from=tools /usr/lib/        /usr/local/lib/
COPY --from=tools /lib/            /usr/local/lib2/
COPY --from=tools /etc/ssl/certs/  /etc/ssl/certs/

ENV LD_LIBRARY_PATH="/usr/local/lib:/usr/local/lib2:$LD_LIBRARY_PATH"
ENV PATH="/usr/local/bin:$PATH"

# FFmpeg environment variables for full compatibility
ENV FFMPEG_PATH="/usr/local/bin/ffmpeg"
ENV FFPROBE_PATH="/usr/local/bin/ffprobe"
ENV FFREPORT="file=/tmp/ffreport-%p-%t.log:level=32"

# FFmpeg runtime directories
RUN mkdir -p /tmp/ffmpeg-temp /tmp/ffmpeg-cache /var/log/ffmpeg && \
    chmod 1777 /tmp/ffmpeg-temp /tmp/ffmpeg-cache /tmp && \
    chmod 755 /var/log/ffmpeg

# Verify ffmpeg binaries are executable and working
RUN chmod +x /usr/local/bin/ffmpeg /usr/local/bin/ffprobe && \
    /usr/local/bin/ffmpeg -version && \
    /usr/local/bin/ffprobe -version

# Create symlinks for common paths where n8n nodes might look for ffmpeg
RUN ln -sf /usr/local/bin/ffmpeg /usr/bin/ffmpeg && \
    ln -sf /usr/local/bin/ffprobe /usr/bin/ffprobe && \
    ln -sf /usr/local/bin/ffmpeg /bin/ffmpeg && \
    ln -sf /usr/local/bin/ffprobe /bin/ffprobe

# ===== هذا الجزء المهم الناقص - الخطوط والـ fontconfig =====
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
    2>/dev/null || true

# تحديث cache الخطوط
RUN fc-cache -fv 2>/dev/null || true

RUN mkdir -p /scripts /backup-data /home/node/.n8n && \
    chown -R node:node /home/node/.n8n /scripts /backup-data

# Ensure node user has access to ffmpeg temp directories
RUN chown -R node:node /tmp/ffmpeg-temp /tmp/ffmpeg-cache /var/log/ffmpeg

USER node

RUN cd /home/node/.n8n && \
    mkdir -p nodes && \
    cd nodes && \
    npm init -y 2>/dev/null && \
    npm install @mookielianhd/n8n-nodes-instagram 2>/dev/null || true

USER root

COPY --chown=node:node scripts/ /scripts/

RUN sed -i 's/\r$//' /scripts/*.sh && \
    chmod 0755 /scripts/*.sh




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
# Final verification that ffmpeg works for node user
USER node
RUN ffmpeg -version && ffprobe -version && \
    fc-list :lang=ar 2>/dev/null | head -5 || echo "Arabic fonts check done" && \
    echo "FFmpeg installation verified successfully"

WORKDIR /home/node

ENTRYPOINT ["sh", "/scripts/start.sh"]
