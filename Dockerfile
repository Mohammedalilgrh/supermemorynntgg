FROM alpine:3.20 AS tools

RUN apk add --no-cache \
      curl jq sqlite tar gzip xz \
      coreutils findutils ca-certificates wget && \
    mkdir -p /toolbox && \
    for cmd in curl jq sqlite3 split sha256sum \
               stat du sort tail awk xargs find \
               wc cut tr gzip tar cat date sleep \
               mkdir rm ls grep sed head touch \
               cp mv basename expr wget; do \
      p="$(which $cmd 2>/dev/null)" && \
        [ -f "$p" ] && cp "$p" /toolbox/ || true; \
    done

# تحميل ffmpeg static
RUN curl -L -o /tmp/ffmpeg.tar.xz https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz && \
    tar -xJf /tmp/ffmpeg.tar.xz -C /tmp/ && \
    cp /tmp/ffmpeg-*-static/ffmpeg /toolbox/ && \
    cp /tmp/ffmpeg-*-static/ffprobe /toolbox/ && \
    rm -rf /tmp/ffmpeg-*-static /tmp/ffmpeg.tar.xz

# تحميل Piper - الرابط الصحيح
RUN mkdir -p /piper-build && \
    cd /piper-build && \
    wget -q --show-progress https://github.com/rhasspy/piper/releases/download/2023.11.14-2/piper_linux_x86_64.tar.gz && \
    tar -xzf piper_linux_x86_64.tar.gz && \
    cp piper/piper /toolbox/ && \
    cp -r piper/espeak-ng-data /toolbox/ && \
    cp piper/lib*.so* /toolbox/ 2>/dev/null || true && \
    chmod +x /toolbox/piper && \
    rm -rf /piper-build

# تحميل الأصوات
RUN mkdir -p /voices-temp && \
    wget -q -O /voices-temp/ar_JO-kareem-medium.onnx \
      "https://huggingface.co/rhasspy/piper-voices/resolve/main/ar/ar_JO/kareem/medium/ar_JO-kareem-medium.onnx" && \
    wget -q -O /voices-temp/ar_JO-kareem-medium.onnx.json \
      "https://huggingface.co/rhasspy/piper-voices/resolve/main/ar/ar_JO/kareem/medium/ar_JO-kareem-medium.onnx.json" && \
    wget -q -O /voices-temp/en_US-lessac-medium.onnx \
      "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/en_US-lessac-medium.onnx" && \
    wget -q -O /voices-temp/en_US-lessac-medium.onnx.json \
      "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/en_US-lessac-medium.onnx.json"

FROM docker.n8n.io/n8nio/n8n:2.6.2

USER root

# نسخ الأدوات
COPY --from=tools /toolbox/        /usr/local/bin/
COPY --from=tools /usr/lib/        /usr/local/lib/
COPY --from=tools /lib/            /usr/local/lib2/
COPY --from=tools /etc/ssl/certs/  /etc/ssl/certs/

# نسخ الأصوات
COPY --from=tools /voices-temp/    /voices/

# نسخ espeak-ng-data لـ Piper
RUN mkdir -p /usr/local/share/piper
COPY --from=tools /toolbox/espeak-ng-data /usr/local/share/piper/espeak-ng-data

ENV LD_LIBRARY_PATH="/usr/local/lib:/usr/local/lib2:/usr/local/bin:$LD_LIBRARY_PATH"
ENV PATH="/usr/local/bin:$PATH"

# FFmpeg environment variables
ENV FFMPEG_PATH="/usr/local/bin/ffmpeg"
ENV FFPROBE_PATH="/usr/local/bin/ffprobe"
ENV FFREPORT="file=/tmp/ffreport-%p-%t.log:level=32"

# Piper environment variables
ENV PIPER_PATH="/usr/local/bin/piper"
ENV VOICES_PATH="/voices"
ENV PIPER_ESPEAK_DATA="/usr/local/share/piper/espeak-ng-data"

# إنشاء المجلدات المؤقتة
RUN mkdir -p /tmp/ffmpeg-temp /tmp/ffmpeg-cache /var/log/ffmpeg /tmp/piper-temp && \
    chmod 1777 /tmp/ffmpeg-temp /tmp/ffmpeg-cache /tmp /tmp/piper-temp && \
    chmod 755 /var/log/ffmpeg /voices && \
    chmod 644 /voices/*.onnx /voices/*.json 2>/dev/null || true

# صلاحيات التشغيل
RUN chmod +x /usr/local/bin/ffmpeg /usr/local/bin/ffprobe /usr/local/bin/piper

# Symlinks لـ ffmpeg
RUN ln -sf /usr/local/bin/ffmpeg /usr/bin/ffmpeg && \
    ln -sf /usr/local/bin/ffprobe /usr/bin/ffprobe && \
    ln -sf /usr/local/bin/ffmpeg /bin/ffmpeg && \
    ln -sf /usr/local/bin/ffprobe /bin/ffprobe

# Symlinks لـ piper
RUN ln -sf /usr/local/bin/piper /usr/bin/piper && \
    ln -sf /usr/local/bin/piper /bin/piper

# تثبيت الخطوط والمكتبات
RUN apt-get update && apt-get install -y --no-install-recommends \
    fontconfig \
    fonts-dejavu \
    fonts-noto \
    fonts-noto-core \
    fonts-noto-ui-core \
    libass9 \
    libfribidi0 \
    libharfbuzz0b \
    libfreetype6 \
    libstdc++6 \
    libgomp1 \
    zlib1g \
    libexpat1 \
    libsndfile1 \
    && rm -rf /var/lib/apt/lists/*

# محاولة تثبيت الخطوط العربية
RUN apt-get update && apt-get install -y --no-install-recommends \
    fonts-arabeyes \
    fonts-kacst \
    2>/dev/null || true && \
    rm -rf /var/lib/apt/lists/*

# تحديث cache الخطوط
RUN fc-cache -fv

# إنشاء المجلدات
RUN mkdir -p /scripts /backup-data /home/node/.n8n && \
    chown -R node:node /home/node/.n8n /scripts /backup-data /tmp/piper-temp

# صلاحيات للمجلدات
RUN chown -R node:node /tmp/ffmpeg-temp /tmp/ffmpeg-cache /var/log/ffmpeg && \
    chmod -R 755 /voices

# تثبيت Instagram node
USER node

RUN cd /home/node/.n8n && \
    mkdir -p nodes && \
    cd nodes && \
    npm init -y 2>/dev/null && \
    npm install @mookielianhd/n8n-nodes-instagram 2>/dev/null || true

USER root

# نسخ السكريبتات
COPY --chown=node:node scripts/ /scripts/

RUN sed -i 's/\r$//' /scripts/*.sh && \
    chmod 0755 /scripts/*.sh

# التحقق النهائي
USER node

RUN echo "=== FFmpeg ===" && \
    ffmpeg -version | head -1 && \
    echo "" && \
    echo "=== Piper ===" && \
    (piper --help 2>&1 | head -3 || echo "Piper installed") && \
    echo "" && \
    echo "=== Voices ===" && \
    ls -la /voices/ && \
    echo "" && \
    echo "=== Arabic Fonts ===" && \
    (fc-list :lang=ar | head -5 || echo "Fonts OK") && \
    echo "" && \
    echo "=== SUCCESS ==="

WORKDIR /home/node

ENTRYPOINT ["sh", "/scripts/start.sh"]
