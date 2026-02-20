FROM alpine:3.19

# Install everything from Alpine repos (all same libc - zero conflicts)
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
      g++ \
      su-exec

# Install n8n globally
RUN npm install -g n8n@2.7.4 --no-audit --no-fund 2>&1 | tail -5

# Create user matching n8n expectations
RUN addgroup -g 1000 node && \
    adduser -u 1000 -G node -s /bin/sh -D node 2>/dev/null || true

# Directories
RUN mkdir -p /scripts /backup-data /backup-data/history /home/node/.n8n && \
    chown -R node:node /home/node/.n8n /scripts /backup-data

COPY --chown=node:node scripts/ /scripts/

RUN sed -i 's/\r$//' /scripts/*.sh && \
    chmod 0755 /scripts/*.sh

ENV N8N_USER_FOLDER=/home/node/.n8n
ENV GENERIC_TIMEZONE=Asia/Baghdad
ENV N8N_DIAGNOSTICS_ENABLED=false
ENV EXECUTIONS_DATA_PRUNE=true
ENV EXECUTIONS_DATA_MAX_AGE=168
ENV EXECUTIONS_DATA_SAVE_ON_SUCCESS=none
ENV HOME=/home/node
ENV PATH="/usr/local/bin:${PATH}"

USER node
WORKDIR /home/node

ENTRYPOINT ["bash", "/scripts/start.sh"]
