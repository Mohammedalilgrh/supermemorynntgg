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
ENV FFMPEG_PATH="/usr/local/bin/ffmpeg"
ENV FFPROBE_PATH="/usr/local/bin/ffprobe"
ENV FFREPORT="file=/tmp/ffreport-%p-%t.log:level=32"

# ======= إضافة edge-tts =======
# تثبيت Python + pip
RUN apk add --no-cache python3 py3-pip && \
    pip3 install --no-cache-dir --break-system-packages edge-tts

# سكريبت مساعد لتوليد الصوت بصوتين فقط
RUN cat > /usr/local/bin/tts-ar << 'EOF'
#!/bin/sh
# Arabic TTS - ar-SA-ZariyahNeural
# Usage: tts-ar "النص هنا" output.mp3
TEXT="$1"
OUTPUT="${2:-/tmp/tts_output.mp3}"
edge-tts --voice ar-SA-ZariyahNeural --text "$TEXT" --write-media "$OUTPUT"
EOF

RUN cat > /usr/local/bin/tts-en << 'EOF'
#!/bin/sh
# English TTS - en-US-AriaNeural
# Usage: tts-en "Your text here" output.mp3
TEXT="$1"
OUTPUT="${2:-/tmp/tts_output.mp3}"
edge-tts --voice en-US-AriaNeural --text "$TEXT" --write-media "$OUTPUT"
EOF

RUN chmod +x /usr/local/bin/tts-ar /usr/local/bin/tts-en

# متغيرات بيئة للأصوات
ENV TTS_VOICE_AR="ar-SA-ZariyahNeural"
ENV TTS_VOICE_EN="en-US-AriaNeural"
# ==============================

RUN mkdir -p /tmp/ffmpeg-temp /tmp/ffmpeg-cache /var/log/ffmpeg && \
    chmod 1777 /tmp/ffmpeg-temp /tmp/ffmpeg-cache /tmp && \
    chmod 755 /var/log/ffmpeg

RUN chmod +x /usr/local/bin/ffmpeg /usr/local/bin/ffprobe && \
    /usr/local/bin/ffmpeg -version && \
    /usr/local/bin/ffprobe -version

RUN ln -sf /usr/local/bin/ffmpeg /usr/bin/ffmpeg && \
    ln -sf /usr/local/bin/ffprobe /usr/bin/ffprobe && \
    ln -sf /usr/local/bin/ffmpeg /bin/ffmpeg && \
    ln -sf /usr/local/bin/ffprobe /bin/ffprobe

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

RUN fc-cache -fv 2>/dev/null || true

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

# التحقق النهائي من كل شيء
USER node
RUN ffmpeg -version && ffprobe -version && \
    edge-tts --list-voices | grep -E "ar-SA-ZariyahNeural|en-US-AriaNeural" && \
    fc-list :lang=ar 2>/dev/null | head -5 || echo "Arabic fonts check done" && \
    echo "✅ FFmpeg + Edge TTS installation verified"

WORKDIR /home/node
ENTRYPOINT ["sh", "/scripts/start.sh"]
