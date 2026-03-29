FROM docker.n8n.io/n8nio/n8n:2.6.2

USER root

# تثبيت FFmpeg والخطوط العربية والمكتبات اللازمة باستخدام apt-get (لأن n8n مبني على Debian)
RUN apt-get update && apt-get install -y \
    ffmpeg \
    fontconfig \
    fonts-dejavu \
    fonts-noto-core \
    fonts-noto-ui-core \
    fonts-noto-arabic \
    libfreetype6 \
    libfribidi0 \
    libharfbuzz0 \
    curl \
    wget \
    && rm -rf /var/lib/apt/lists/*

# تحديث كاش الخطوط ليتعرف FFmpeg عليها
RUN fc-cache -fv

# إعداد المجلدات والصلاحيات
RUN mkdir -p /scripts /backup-data /home/node/.n8n /tmp/ffmpeg-temp && \
    chown -R node:node /home/node/.n8n /scripts /backup-data /tmp/ffmpeg-temp && \
    chmod 1777 /tmp/ffmpeg-temp

# تثبيت نودات إضافية (إذا كنت تحتاجها)
USER node
RUN cd /home/node/.n8n && \
    mkdir -p nodes && \
    cd nodes && \
    npm init -y && \
    npm install @mookielianhd/n8n-nodes-instagram || true

USER root
COPY --chown=node:node scripts/ /scripts/
RUN sed -i 's/\r$//' /scripts/*.sh && \
    chmod 0755 /scripts/*.sh

USER node
WORKDIR /home/node

ENTRYPOINT ["sh", "/scripts/start.sh"]
