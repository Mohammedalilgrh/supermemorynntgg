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

FROM docker.n8n.io/n8nio/n8n:2.6.2

USER root

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

# ===== الخطوط والـ fontconfig =====
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

# ============================================================
# ⭐ Piper TTS — British Voice (en_GB-vctk-medium, speaker 9)
# ============================================================
# gcompat: طبقة توافق glibc على Alpine لتشغيل الـ binary
RUN apk add --no-cache gcompat

# تحميل Piper binary (يحتوي على onnxruntime داخله)
RUN curl -L -o /tmp/piper.tar.gz \
    "https://github.com/rhasspy/piper/releases/download/2023.11.14-2/piper_linux_x86_64.tar.gz" && \
    mkdir -p /usr/local/piper && \
    tar -xzf /tmp/piper.tar.gz -C /usr/local/piper --strip-components=1 && \
    rm /tmp/piper.tar.gz && \
    ln -sf /usr/local/piper/piper /usr/local/bin/piper && \
    chmod +x /usr/local/piper/piper

# تحميل الصوت البريطاني: en_GB-vctk-medium
# speaker 9 = صوت ذكر بريطاني واضح
RUN mkdir -p /usr/local/piper-voices && \
    curl -L -o /usr/local/piper-voices/en_GB-vctk-medium.onnx \
    "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/vctk/medium/en_GB-vctk-medium.onnx" && \
    curl -L -o /usr/local/piper-voices/en_GB-vctk-medium.onnx.json \
    "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/vctk/medium/en_GB-vctk-medium.onnx.json"

# متغيرات البيئة لـ Piper
ENV PIPER_MODEL="/usr/local/piper-voices/en_GB-vctk-medium.onnx"
ENV PIPER_SPEAKER="9"
# مهم: Piper يحتاج libs داخل مجلده
ENV LD_LIBRARY_PATH="/usr/local/piper:${LD_LIBRARY_PATH}"

# سكريبت tts-piper: يولّد WAV
# للحصول على MP3 استخدم ffmpeg بعده
RUN cat > /usr/local/bin/tts-piper << 'EOF'
#!/bin/sh
# Usage: tts-piper "your text" /tmp/output.wav
# Output: WAV file (use ffmpeg to convert to mp3 if needed)
TEXT="$1"
OUT_WAV="${2:-/tmp/piper_out.wav}"
OUT_MP3="${OUT_WAV%.wav}.mp3"

echo "$TEXT" | piper \
  --model /usr/local/piper-voices/en_GB-vctk-medium.onnx \
  --speaker 9 \
  --output_file "$OUT_WAV"

# تحويل تلقائي لـ MP3 لو طلبت ملف .mp3
case "$2" in
  *.mp3)
    ffmpeg -y -i "$OUT_WAV" -codec:a libmp3lame -qscale:a 2 "$2" 2>/dev/null
    rm -f "$OUT_WAV"
    echo "✅ MP3: $2"
    ;;
  *)
    echo "✅ WAV: $OUT_WAV"
    ;;
esac
EOF
RUN chmod +x /usr/local/bin/tts-piper
# ============================================================

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

# Final verification
USER node
RUN ffmpeg -version && ffprobe -version && \
    piper --version 2>/dev/null || piper --help 2>&1 | head -2 && \
    ls -lh /usr/local/piper-voices/ && \
    fc-list :lang=ar 2>/dev/null | head -5 || echo "Arabic fonts check done" && \
    echo "✅ FFmpeg + Piper TTS installation verified"

WORKDIR /home/node

ENTRYPOINT ["sh", "/scripts/start.sh"]
