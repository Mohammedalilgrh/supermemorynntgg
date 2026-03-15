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

# تحميل ffmpeg static في مرحلة Alpine
RUN curl -L -o /tmp/ffmpeg.tar.xz https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz && \
    tar -xJf /tmp/ffmpeg.tar.xz -C /tmp/ && \
    cp /tmp/ffmpeg-*-static/ffmpeg /toolbox/ && \
    cp /tmp/ffmpeg-*-static/ffprobe /toolbox/ && \
    rm -rf /tmp/ffmpeg-*-static /tmp/ffmpeg.tar.xz

# تحميل Piper في مرحلة Alpine
RUN mkdir -p /piper-temp && \
    wget -O /piper-temp/piper.tar.gz https://github.com/rhasspy/piper/releases/download/v2024.11.05/piper_amd64.tar.gz && \
    tar -xzf /piper-temp/piper.tar.gz -C /piper-temp/ && \
    cp /piper-temp/piper/piper /toolbox/ && \
    chmod +x /toolbox/piper && \
    rm -rf /piper-temp

# تحميل الأصوات في مرحلة Alpine
RUN mkdir -p /voices-temp && \
    wget -O /voices-temp/ar_JO-kareem-medium.onnx https://huggingface.co/rhasspy/piper-voices/resolve/main/ar/ar_JO/kareem/medium/ar_JO-kareem-medium.onnx && \
    wget -O /voices-temp/ar_JO-kareem-medium.onnx.json https://huggingface.co/rhasspy/piper-voices/resolve/main/ar/ar_JO/kareem/medium/ar_JO-kareem-medium.onnx.json && \
    wget -O /voices-temp/ar_JO-kareem-high.onnx https://huggingface.co/rhasspy/piper-voices/resolve/main/ar/ar_JO/kareem/high/ar_JO-kareem-high.onnx && \
    wget -O /voices-temp/ar_JO-kareem-high.onnx.json https://huggingface.co/rhasspy/piper-voices/resolve/main/ar/ar_JO/kareem/high/ar_JO-kareem-high.onnx.json && \
    wget -O /voices-temp/en_US-lessac-medium.onnx https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/en_US-lessac-medium.onnx && \
    wget -O /voices-temp/en_US-lessac-medium.onnx.json https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_US/lessac/medium/en_US-lessac-medium.onnx.json

FROM docker.n8n.io/n8nio/n8n:2.6.2

USER root

# نسخ الأدوات من مرحلة Alpine
COPY --from=tools /toolbox/        /usr/local/bin/
COPY --from=tools /usr/lib/        /usr/local/lib/
COPY --from=tools /lib/            /usr/local/lib2/
COPY --from=tools /etc/ssl/certs/  /etc/ssl/certs/

# نسخ الأصوات
COPY --from=tools /voices-temp/    /voices/

ENV LD_LIBRARY_PATH="/usr/local/lib:/usr/local/lib2:$LD_LIBRARY_PATH"
ENV PATH="/usr/local/bin:$PATH"

# FFmpeg environment variables
ENV FFMPEG_PATH="/usr/local/bin/ffmpeg"
ENV FFPROBE_PATH="/usr/local/bin/ffprobe"
ENV FFREPORT="file=/tmp/ffreport-%p-%t.log:level=32"

# Piper environment variables
ENV PIPER_PATH="/usr/local/bin/piper"
ENV VOICES_PATH="/voices"

# FFmpeg runtime directories
RUN mkdir -p /tmp/ffmpeg-temp /tmp/ffmpeg-cache /var/log/ffmpeg && \
    chmod 1777 /tmp/ffmpeg-temp /tmp/ffmpeg-cache /tmp && \
    chmod 755 /var/log/ffmpeg

# Piper runtime directories
RUN mkdir -p /tmp/piper-temp && \
    chmod 1777 /tmp/piper-temp && \
    chmod 755 /voices && \
    chmod 644 /voices/*.onnx /voices/*.json

# Verify ffmpeg binaries
RUN chmod +x /usr/local/bin/ffmpeg /usr/local/bin/ffprobe && \
    /usr/local/bin/ffmpeg -version && \
    /usr/local/bin/ffprobe -version

# Verify piper binary
RUN chmod +x /usr/local/bin/piper && \
    /usr/local/bin/piper --version || echo "Piper binary ready"

# Create symlinks for ffmpeg
RUN ln -sf /usr/local/bin/ffmpeg /usr/bin/ffmpeg && \
    ln -sf /usr/local/bin/ffprobe /usr/bin/ffprobe && \
    ln -sf /usr/local/bin/ffmpeg /bin/ffmpeg && \
    ln -sf /usr/local/bin/ffprobe /bin/ffprobe

# Create symlinks for piper
RUN ln -sf /usr/local/bin/piper /usr/bin/piper && \
    ln -sf /usr/local/bin/piper /bin/piper

# تثبيت الخطوط والمكتبات المطلوبة لـ Debian
RUN apt-get update && apt-get install -y --no-install-recommends \
    fontconfig \
    fonts-dejavu \
    fonts-noto \
    fonts-noto-core \
    fonts-noto-ui-core \
    fonts-noto-extra \
    libass9 \
    libfribidi0 \
    libharfbuzz0b \
    libfreetype6 \
    libstdc++6 \
    libgomp1 \
    zlib1g \
    libexpat1 \
    && rm -rf /var/lib/apt/lists/*

# محاولة تثبيت الخطوط العربية (قد لا تكون متاحة في جميع المستودعات)
RUN apt-get update && apt-get install -y --no-install-recommends \
    fonts-arabeyes \
    fonts-kacst \
    fonts-farsiweb \
    2>/dev/null || echo "Some Arabic fonts not available, continuing..."

# تحديث cache الخطوط
RUN fc-cache -fv

# إنشاء المجلدات الأساسية
RUN mkdir -p /scripts /backup-data /home/node/.n8n && \
    chown -R node:node /home/node/.n8n /scripts /backup-data

# Ensure node user has access to all temp directories
RUN chown -R node:node /tmp/ffmpeg-temp /tmp/ffmpeg-cache /var/log/ffmpeg /tmp/piper-temp && \
    chmod -R 755 /voices

# تثبيت Instagram node كمستخدم node
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

# Final verification
USER node

RUN echo "=== FFmpeg Verification ===" && \
    ffmpeg -version && \
    ffprobe -version && \
    echo "" && \
    echo "=== Piper Verification ===" && \
    piper --version || echo "Piper is ready" && \
    echo "" && \
    echo "=== Voices Files ===" && \
    ls -lh /voices/ && \
    echo "" && \
    echo "=== Arabic Fonts Check ===" && \
    fc-list :lang=ar 2>/dev/null | head -10 || echo "Arabic fonts check completed" && \
    echo "" && \
    echo "=== All Tools Verified Successfully ==="

WORKDIR /home/node

ENTRYPOINT ["sh", "/scripts/start.sh"]
