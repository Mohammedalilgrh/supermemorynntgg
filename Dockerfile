FROM alpine:3.20 AS tools

# تثبيت الأدوات الأساسية
RUN apk add --no-cache \
      curl jq sqlite tar gzip xz wget \
      coreutils findutils ca-certificates

# تحميل FFmpeg static
RUN mkdir -p /toolbox && \
    curl -L -o /tmp/ffmpeg.tar.xz https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz && \
    tar -xJf /tmp/ffmpeg.tar.xz -C /tmp/ && \
    cp /tmp/ffmpeg-*-static/ffmpeg /toolbox/ && \
    cp /tmp/ffmpeg-*-static/ffprobe /toolbox/ && \
    chmod +x /toolbox/ffmpeg /toolbox/ffprobe && \
    rm -rf /tmp/ffmpeg-*-static /tmp/ffmpeg.tar.xz

# تحميل Piper (الرابط الصحيح)
RUN mkdir -p /piper-build && \
    cd /piper-build && \
    wget -q https://github.com/rhasspy/piper/releases/download/2023.11.14-2/piper_linux_x86_64.tar.gz && \
    tar -xzf piper_linux_x86_64.tar.gz && \
    cp -r piper /toolbox/piper-full && \
    chmod +x /toolbox/piper-full/piper && \
    rm -rf /piper-build

# تحميل الأصوات مع ملفات JSON
RUN mkdir -p /voices && \
    wget -q -O /voices/ar_JO-kareem-medium.onnx \
      "https://huggingface.co/rhasspy/piper-voices/resolve/main/ar/ar_JO/kareem/medium/ar_JO-kareem-medium.onnx" && \
    wget -q -O /voices/ar_JO-kareem-medium.onnx.json \
      "https://huggingface.co/rhasspy/piper-voices/resolve/main/ar/ar_JO/kareem/medium/ar_JO-kareem-medium.onnx.json" && \
    wget -q -O /voices/ar_JO-kareem-high.onnx \
      "https://huggingface.co/rhasspy/piper-voices/resolve/main/ar/ar_JO/kareem/high/ar_JO-kareem-high.onnx" && \
    wget -q -O /voices/ar_JO-kareem-high.onnx.json \
      "https://huggingface.co/rhasspy/piper-voices/resolve/main/ar/ar_JO/kareem/high/ar_JO-kareem-high.onnx.json" && \
    wget -q -O /voices/en_US-lessac-medium.onnx \
      "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/en_US-lessac-medium.onnx" && \
    wget -q -O /voices/en_US-lessac-medium.onnx.json \
      "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/en_US-lessac-medium.onnx.json"

# ========================================
# المرحلة النهائية
# ========================================
FROM docker.n8n.io/n8nio/n8n:2.6.2

USER root

# نسخ FFmpeg (static - لا يحتاج مكتبات)
COPY --from=tools /toolbox/ffmpeg   /usr/local/bin/ffmpeg
COPY --from=tools /toolbox/ffprobe  /usr/local/bin/ffprobe

# نسخ Piper مع كل ملفاته
COPY --from=tools /toolbox/piper-full /opt/piper

# نسخ الأصوات
COPY --from=tools /voices /voices

# ===== تثبيت الحزم باستخدام apk (Alpine) =====
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
    libsndfile \
    curl \
    jq \
    sqlite \
    wget \
    bash \
    coreutils \
    findutils

# تحديث cache الخطوط
RUN fc-cache -fv

# صلاحيات FFmpeg
RUN chmod +x /usr/local/bin/ffmpeg /usr/local/bin/ffprobe

# Symlinks لـ FFmpeg
RUN ln -sf /usr/local/bin/ffmpeg /usr/bin/ffmpeg && \
    ln -sf /usr/local/bin/ffprobe /usr/bin/ffprobe && \
    ln -sf /usr/local/bin/ffmpeg /bin/ffmpeg && \
    ln -sf /usr/local/bin/ffprobe /bin/ffprobe

# صلاحيات Piper و symlinks
RUN chmod +x /opt/piper/piper && \
    ln -sf /opt/piper/piper /usr/local/bin/piper && \
    ln -sf /opt/piper/piper /usr/bin/piper

# متغيرات البيئة
ENV PATH="/usr/local/bin:/opt/piper:$PATH"
ENV LD_LIBRARY_PATH="/opt/piper:$LD_LIBRARY_PATH"

# FFmpeg
ENV FFMPEG_PATH="/usr/local/bin/ffmpeg"
ENV FFPROBE_PATH="/usr/local/bin/ffprobe"
ENV FFREPORT="file=/tmp/ffreport-%p-%t.log:level=32"

# Piper
ENV PIPER_PATH="/opt/piper/piper"
ENV VOICES_PATH="/voices"

# إنشاء المجلدات المؤقتة
RUN mkdir -p /tmp/ffmpeg-temp /tmp/ffmpeg-cache /tmp/piper-temp /var/log/ffmpeg && \
    chmod 1777 /tmp/ffmpeg-temp /tmp/ffmpeg-cache /tmp/piper-temp /tmp && \
    chmod 755 /var/log/ffmpeg /voices && \
    chmod 644 /voices/*.onnx /voices/*.json

# إنشاء مجلدات العمل
RUN mkdir -p /scripts /backup-data /home/node/.n8n && \
    chown -R node:node /home/node/.n8n /scripts /backup-data \
    /tmp/ffmpeg-temp /tmp/ffmpeg-cache /tmp/piper-temp /var/log/ffmpeg

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

RUN sed -i 's/\r$//' /scripts/*.sh 2>/dev/null || true && \
    chmod 0755 /scripts/*.sh 2>/dev/null || true

# ===== التحقق النهائي =====
USER node

RUN echo "============================================" && \
    echo "           VERIFICATION STARTED             " && \
    echo "============================================" && \
    echo "" && \
    echo ">>> FFmpeg:" && \
    ffmpeg -version | head -1 && \
    echo "" && \
    echo ">>> FFprobe:" && \
    ffprobe -version | head -1 && \
    echo "" && \
    echo ">>> Piper:" && \
    /opt/piper/piper --help 2>&1 | head -3 || echo "Piper binary ready" && \
    echo "" && \
    echo ">>> Voice Files:" && \
    ls -lh /voices/ && \
    echo "" && \
    echo ">>> Arabic Fonts:" && \
    fc-list :lang=ar | head -5 || echo "Arabic fonts available" && \
    echo "" && \
    echo "============================================" && \
    echo "          ALL SYSTEMS READY ✓              " && \
    echo "============================================"

WORKDIR /home/node

ENTRYPOINT ["sh", "/scripts/start.sh"]
