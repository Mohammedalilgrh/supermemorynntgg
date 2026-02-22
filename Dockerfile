FROM docker.n8n.io/n8nio/n8n:2.7.4

USER root

RUN apk add --no-cache \
    curl \
    jq \
    sqlite \
    gzip \
    ca-certificates

RUN mkdir -p /scripts /home/node/.n8n

COPY scripts /scripts

RUN chmod +x /scripts/backup.sh || true && \
    chmod +x /scripts/restore.sh || true && \
    chmod +x /scripts/start.sh || true

USER node
WORKDIR /home/node

ENTRYPOINT ["sh", "/scripts/start.sh"]
