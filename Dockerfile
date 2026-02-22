FROM node:20-alpine AS tools

RUN apk add --no-cache curl jq sqlite gzip ca-certificates

FROM docker.n8n.io/n8nio/n8n:2.7.4

USER root

COPY --from=tools /usr/bin/curl /usr/bin/curl
COPY --from=tools /usr/bin/jq /usr/bin/jq
COPY --from=tools /usr/bin/sqlite3 /usr/bin/sqlite3
COPY --from=tools /usr/bin/gzip /usr/bin/gzip
COPY --from=tools /usr/bin/gunzip /usr/bin/gunzip
COPY --from=tools /etc/ssl/certs /etc/ssl/certs

RUN mkdir -p /scripts /home/node/.n8n && \
    chown -R node:node /home/node/.n8n /scripts

COPY scripts /scripts

RUN chmod +x /scripts/*.sh

USER node
WORKDIR /home/node

ENTRYPOINT ["sh", "/scripts/start.sh"]
