FROM docker.n8n.io/n8nio/n8n:2.7.4

USER root

# بما أن النظام مبني على Debian/Ubuntu يجب استخدام apt-get بدلاً من apk
RUN apt-get update && \
    apt-get install -y curl jq sqlite3 tar gzip coreutils findutils ca-certificates tzdata && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p /scripts /backup-data /home/node/.n8n && \
    chown -R node:node /home/node/.n8n /scripts /backup-data

COPY --chown=node:node scripts/ /scripts/

# إصلاح نهايات الأسطر (لو تم رفعها من ويندوز) وإعطاء صلاحيات التشغيل
RUN sed -i 's/\r$//' /scripts/*.sh && \
    chmod 0755 /scripts/*.sh

USER node
WORKDIR /home/node

ENTRYPOINT ["sh", "/scripts/start.sh"]
