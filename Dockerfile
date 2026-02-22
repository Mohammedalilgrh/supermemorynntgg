FROM docker.n8n.io/n8nio/n8n:2.7.4

USER root

RUN mkdir -p /scripts /home/node/.n8n && \
    chown -R node:node /home/node/.n8n /scripts

COPY scripts /scripts

RUN chmod +x /scripts/*.sh

USER node
WORKDIR /home/node

ENTRYPOINT ["sh", "/scripts/start.sh"]
