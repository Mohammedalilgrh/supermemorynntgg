FROM alpine:3.20 AS tools

RUN apk add --no-cache \
FROM alpine:3.20 AS tools
      curl jq sqlite tar gzip \
      ffmpeg \
      coreutils findutils ca-certificates && \
    mkdir -p /toolbox && \
    for cmd in curl jq sqlite3 split sha256sum \
               stat du sort tail awk xargs find \
               wc cut tr gzip tar cat date sleep \
               mkdir rm ls grep sed head touch \
               cp mv basename expr; do \
      p="$(which $cmd 2>/dev/null)" && \
        [ -f "$p" ] && cp "$p" /toolbox/ || true; \
    done

FROM docker.n8n.io/n8nio/n8n:2.6.2

USER root

COPY --from=tools /toolbox/        /usr/local/bin/
COPY --from=tools /usr/lib/        /usr/local/lib/
COPY --from=tools /lib/            /usr/local/lib2/
COPY --from=tools /etc/ssl/certs/  /etc/ssl/certs/

ENV LD_LIBRARY_PATH="/usr/local/lib:/usr/local/lib2:$LD_LIBRARY_PATH"
ENV PATH="/usr/local/bin:$PATH"

RUN mkdir -p /scripts /backup-data /home/node/.n8n && \
    chown -R node:node /home/node/.n8n /scripts /backup-data

# ══════════════════════════════════════
# ⭐ Install community nodes here
# Add any node you need
# ══════════════════════════════════════
USER node

RUN cd /home/node/.n8n && \
    mkdir -p nodes && \
    cd nodes && \
    npm init -y 2>/dev/null && \
    npm install @mookielianhd/n8n-nodes-instagram 2>/dev/null || true

# Add more nodes like this:
# RUN cd /home/node/.n8n/nodes && \
#     npm install n8n-nodes-some-other-node 2>/dev/null || true

USER root

COPY --chown=node:node scripts/ /scripts/

RUN sed -i 's/\r$//' /scripts/*.sh && \
    chmod 0755 /scripts/*.sh

USER node
WORKDIR /home/node

ENTRYPOINT ["sh", "/scripts/start.sh"]
