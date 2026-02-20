FROM node:18-alpine AS tools

RUN apk add --no-cache \
      curl \
      jq \
      sqlite \
      tar \
      gzip \
      coreutils \
      findutils \
      ca-certificates \
      bash

FROM docker.n8n.io/n8nio/n8n:latest

USER root

RUN apk add --no-cache \
      curl \
      jq \
      sqlite \
      tar \
      gzip \
      coreutils \
      findutils \
      ca-certificates \
      bash \
      tini && \
    mkdir -p /scripts /backup-data /backup-data/history /home/node/.n8n && \
    chown -R node:node /home/node/.n8n /scripts /backup-data

COPY --chown=node:node scripts/ /scripts/

RUN find /scripts -name "*.sh" -exec sed -i 's/\r$//' {} \; && \
    find /scripts -name "*.sh" -exec chmod 0755 {} \;

ENV N8N_USER_FOLDER=/home/node/.n8n
ENV GENERIC_TIMEZONE=Asia/Baghdad
ENV N8N_DIAGNOSTICS_ENABLED=false
ENV EXECUTIONS_DATA_PRUNE=true
ENV EXECUTIONS_DATA_MAX_AGE=168
ENV EXECUTIONS_DATA_SAVE_ON_SUCCESS=none
ENV DB_SQLITE_VACUUM_ON_STARTUP=true

USER node
WORKDIR /home/node

ENTRYPOINT ["sh", "/scripts/start.sh"]
