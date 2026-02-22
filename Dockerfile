FROM docker.n8n.io/n8nio/n8n:2.7.4

USER root

RUN apt-get update && \
    apt-get install -y curl jq sqlite3 gzip ca-certificates && \
    rm -rf /var/lib/apt/lists/*

RUN mkdir -p /scripts /home/node/.n8n

COPY scripts /scripts

RUN chmod +x /scripts/backup.sh && \
    chmod +x /scripts/restore.sh && \
    chmod +x /scripts/start.sh

USER node
WORKDIR /home/node

ENTRYPOINT ["sh", "/scripts/start.sh"]
