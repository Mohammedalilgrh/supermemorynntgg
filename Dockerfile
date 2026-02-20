FROM alpine:3.20

# Alpine 3.20 has Node.js 20.19+ which satisfies n8n requirements
RUN apk add --no-cache \
      nodejs \
      npm \
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

# Install n8n
RUN npm install -g n8n@2.7.4 --no-audit --no-fund 2>&1 | tail -5

# Verify node version
RUN node --version && n8n --version || true

# Create node user
RUN addgroup -g 1000 node 2>/dev/null || true && \
    adduser -u 1000 -G node -s /bin/sh -D node 2>/dev/null || true

# Directories
RUN mkdir -p /scripts /backup-data /backup-data/history /home/node/.n8n && \
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
ENV HOME=/home/node

USER node
WORKDIR /home/node

ENTRYPOINT ["bash", "/scripts/start.sh"]
