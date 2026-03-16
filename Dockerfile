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

# تحميل ffmpeg static في مرحلة Alpine
RUN curl -L -o /tmp/ffmpeg.tar.xz https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz && \
    tar -xJf /tmp/ffmpeg.tar.xz -C /tmp/ && \
    cp /tmp/ffmpeg-*-static/ffmpeg /toolbox/ && \
    cp /tmp/ffmpeg-*-static/ffprobe /toolbox/ && \
    rm -rf /tmp/ffmpeg-*-static /tmp/ffmpeg.tar.xz

# تحميل Piper binary في مرحلة Alpine (حيث curl متاح بشكل موثوق)
RUN curl -L -o /tmp/piper.tar.gz \
    "https://github.com/rhasspy/piper/releases/download/2023.11.14-2/piper_linux_x86_64.tar.gz" && \
    mkdir -p /tmp/piper-bin && \
    tar -xzf /tmp/piper.tar.gz -C /tmp/piper-bin --strip-components=1 && \
    rm /tmp/piper.tar.gz

# تحميل ملفات النموذج البريطاني en_GB-vctk-medium
RUN mkdir -p /tmp/piper-voices && \
    curl -L -o /tmp/piper-voices/en_GB-vctk-medium.onnx \
    "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/vctk/medium/en_GB-vctk-medium.onnx" && \
    curl -L -o /tmp/piper-voices/en_GB-vctk-medium.onnx.json \
    "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/vctk/medium/en_GB-vctk-medium.onnx.json"

# ─────────────────────────────────────────────────
FROM docker.n8n.io/n8nio/n8n:2.6.2

USER root

COPY --from=tools /toolbox/           /usr/local/bin/
COPY --from=tools /usr/lib/           /usr/local/lib/
COPY --from=tools /lib/               /usr/local/lib2/
COPY --from=tools /etc/ssl/certs/     /etc/ssl/certs/
COPY --from=tools /tmp/piper-bin/     /usr/local/piper/
COPY --from=tools /tmp/piper-voices/  /usr/local/piper-voices/

ENV LD_LIBRARY_PATH="/usr/local/lib:/usr/local/lib2:/usr/local/piper:$LD_LIBRARY_PATH"
ENV PATH="/usr/local/bin:/usr/local/piper:$PATH"

# FFmpeg environment variables
ENV FFMPEG_PATH="/usr/local/bin/ffmpeg"
ENV FFPROBE_PATH="/usr/local/bin/ffprobe"
ENV FFREPORT="file=/tmp/ffreport-%p-%t.log:level=32"

# Piper environment variables
ENV PIPER_MODEL="/usr/local/piper-voices/en_GB-vctk-medium.onnx"
ENV PIPER_SPEAKER="9"

# FFmpeg runtime directories
RUN mkdir -p /tmp/ffmpeg-temp /tmp/ffmpeg-cache /var/log/ffmpeg && \
    chmod 1777 /tmp/ffmpeg-temp /tmp/ffmpeg-cache /tmp && \
    chmod 755 /var/log/ffmpeg

# Verify ffmpeg
RUN chmod +x /usr/local/bin/ffmpeg /usr/local/bin/ffprobe && \
    /usr/local/bin/ffmpeg -version && \
    /usr/local/bin/ffprobe -version

# Symlinks for ffmpeg
RUN ln -sf /usr/local/bin/ffmpeg /usr/bin/ffmpeg && \
    ln -sf /usr/local/bin/ffprobe /usr/bin/ffprobe && \
    ln -sf /usr/local/bin/ffmpeg /bin/ffmpeg && \
    ln -sf /usr/local/bin/ffprobe /bin/ffprobe

# ── الخطوط: نجرب apk (Alpine) وإلا apt-get (Debian) ──
RUN (apk add --no-cache \
      fontconfig ttf-dejavu font-noto font-noto-arabic font-noto-extra \
      libass fribidi harfbuzz freetype libstdc++ libgcc libgomp zlib expat \
      2>/dev/null) || \
    (apt-get update -qq 2>/dev/null && apt-get install -y --no-install-recommends \
      fontconfig fonts-dejavu fonts-noto fonts-noto-core \
      libass9 libfribidi0 libharfbuzz0b libfreetype6 \
      libstdc++6 zlib1g libexpat1 \
      2>/dev/null && rm -rf /var/lib/apt/lists/*) || true

RUN fc-cache -fv 2>/dev/null || true

# ── Piper: إعداد البinary والسكريبت ──
RUN chmod +x /usr/local/piper/piper && \
    ln -sf /usr/local/piper/piper /usr/local/bin/piper

# سكريبت tts-en: British voice speaker 9 — يخرج WAV أو MP3
RUN cat > /usr/local/bin/tts-en << 'EOF'
#!/bin/sh
# Piper TTS — en_GB-vctk-medium, speaker 9
# Usage:
#   tts-en "Hello there" /tmp/out.wav    -> WAV مباشرة
#   tts-en "Hello there" /tmp/out.mp3    -> MP3 (تحويل تلقائي)
TEXT="$1"
OUTPUT="${2:-/tmp/tts_out.wav}"

case "$OUTPUT" in
  *.mp3)
    TMP_WAV="/tmp/_piper_$$.wav"
    echo "$TEXT" | piper \
      --model /usr/local/piper-voices/en_GB-vctk-medium.onnx \
      --speaker 9 \
      --output_file "$TMP_WAV" && \
    ffmpeg -y -i "$TMP_WAV" -codec:a libmp3lame -qscale:a 2 "$OUTPUT" 2>/dev/null && \
    rm -f "$TMP_WAV"
    echo "Done: $OUTPUT"
    ;;
  *)
    echo "$TEXT" | piper \
      --model /usr/local/piper-voices/en_GB-vctk-medium.onnx \
      --speaker 9 \
      --output_file "$OUTPUT"
    echo "Done: $OUTPUT"
    ;;
esac
EOF
RUN chmod +x /usr/local/bin/tts-en

RUN mkdir -p /scripts /backup-data /home/node/.n8n && \
    chown -R node:node /home/node/.n8n /scripts /backup-data

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

# التحقق النهائي
USER node
RUN ffmpeg -version && ffprobe -version && \
    ls -lh /usr/local/piper-voices/ && \
    echo "Hello Piper" | piper \
      --model /usr/local/piper-voices/en_GB-vctk-medium.onnx \
      --speaker 9 \
      --output_file /tmp/test_piper.wav 2>/dev/null && \
    echo "✅ Piper TTS working — en_GB speaker 9" || \
    echo "⚠️ Piper test failed — check logs" && \
    echo "✅ Build complete"

WORKDIR /home/node

ENTRYPOINT ["sh", "/scripts/start.sh"]
