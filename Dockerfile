FROM docker.n8n.io/n8nio/n8n:2.7.4

USER root

# نرجّع كل الأدوات الأساسية اللي ناقصة في n8n image (الحل الرسمي)
RUN apk add --no-cache \
    curl \
    jq \
    sqlite \
    tar \
    gzip \
    coreutils \
    findutils \
    ca-certificates

# مجلدات + TMP داخل home بدل /tmp (الحل النهائي لمشكلة Render Free 2025)
RUN mkdir -p /home/node/tmp /scripts /backup-data && \
    chown -R node:node /home/node/.n8n /home/node/tmp /scripts /backup-data

# المتغيرات السحرية
ENV TMPDIR=/home/node/tmp
ENV TMP=/home/node/tmp
ENV TEMP=/home/node/tmp
ENV NODE_OPTIONS="--max-old-space-size=512"

# نسخ السكربتات
COPY --chown=node:node scripts/ /scripts/

# صلاحيات + تنظيف \r
RUN find /scripts -type f -name "*.sh" -exec chmod +x {} \; && \
    find /scripts -type f -name "*.sh" -exec sed -i 's/\r$//' {} \;

USER node
WORKDIR /home/node

ENTRYPOINT ["sh", "/scripts/start.sh"]
