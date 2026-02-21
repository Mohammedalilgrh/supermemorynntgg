FROM node:20-alpine

RUN apk add --no-cache \
      curl \
      jq \
      sqlite \
      coreutils \
      findutils \
      bash \
      tar \
      gzip \
      ca-certificates \
      python3 \
      make \
      g++

# Install n8n - latest stable that supports node 20
RUN npm install -g n8n@latest --no-audit --no-fund 2>&1 | tail -3

# Verify
RUN echo "=== Versions ===" && \
    node --version && \
    n8n --version

# User
RUN addgroup -g 1000 node 2>/dev/null || true && \
    adduser -u 1000 -G node -s /bin/sh -D node 2>/dev/null || true

# Dirs
RUN mkdir -p /scripts /backup-data /backup-data/history /home/node/.n8n && \
    chown -R node:node /home/node/.n8n /scripts /backup-data

COPY --chown=node:node scripts/ /scripts/

RUN find /scripts -name "*.sh" \
      -exec sed -i 's/\r$//' {} \; \
      -exec chmod 0755 {} \;

ENV N8N_USER_FOLDER=/home/node/.n8n
ENV GENERIC_TIMEZONE=Asia/Baghdad
ENV N8N_DIAGNOSTICS_ENABLED=false
ENV EXECUTIONS_DATA_PRUNE=true
ENV EXECUTIONS_DATA_MAX_AGE=168
ENV EXECUTIONS_DATA_SAVE_ON_SUCCESS=none
ENV HOME=/home/node
ENV N8N_RUNNERS_ENABLED=false

USER node
WORKDIR /home/node

ENTRYPOINT ["bash", "/scripts/start.sh"]
