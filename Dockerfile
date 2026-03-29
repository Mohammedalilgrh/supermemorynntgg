FROM docker.n8n.io/n8nio/n8n:2.6.2

USER root

# تثبيت FFmpeg والخطوط العربية باستخدام apk (الخاص بـ Alpine)
RUN apk add --no-cache \
    ffmpeg \
    fontconfig \
    ttf-dejavu \
    font-noto \
    font-noto-arabic \
    curl \
    wget \
    bash

# تحديث كاش الخطوط
RUN fc-cache -fv

# إعداد المجلدات والصلاحيات
RUN mkdir -p /scripts /backup-data /home/node/.n8n /tmp/ffmpeg-temp && \
    chown -R node:node /home/node/.n8n /scripts /backup-data /tmp/ffmpeg-temp && \
    chmod 1777 /tmp/ffmpeg-temp

# تثبيت نودات إضافية
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
