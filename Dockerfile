FROM docker.n8n.io/n8nio/n8n:2.7.4

USER root

# Install tools directly (avoids multi-stage issues)
RUN apk add --no-cache \
      curl jq sqlite tar gzip \
      coreutils findutils ca-certificates && \
    mkdir -p /scripts /backup-data /home/node/.n8n && \
    chown -R node:node /home/node/.n8n /scripts /backup-data

COPY --chown=node:node scripts/ /scripts/
RUN sed -i 's/\r$//' /scripts/*.sh && chmod 0755 /scripts/*.sh

USER node
WORKDIR /home/node
ENTRYPOINT ["sh", "/scripts/start.sh"]
