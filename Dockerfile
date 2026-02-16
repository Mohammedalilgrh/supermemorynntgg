FROM alpine:3.20 AS tools
RUN apk add --no-cache curl jq sqlite tar gzip coreutils findutils ca-certificates && \
    mkdir -p /t && \
    for c in curl jq sqlite3 split sha256sum stat du sort tail \
             awk xargs find wc cut tr gzip tar cat date sleep \
             mkdir rm ls grep sed head touch cp mv basename expr; do \
      p="$(which $c 2>/dev/null)" && [ -f "$p" ] && cp "$p" /t/ || true; \
    done

FROM docker.n8n.io/n8nio/n8n:2.3.6
USER root
COPY --from=tools /t/             /usr/local/bin/
COPY --from=tools /usr/lib/       /usr/local/lib/
COPY --from=tools /lib/           /usr/local/lib2/
COPY --from=tools /etc/ssl/certs/ /etc/ssl/certs/
ENV LD_LIBRARY_PATH="/usr/local/lib:/usr/local/lib2:$LD_LIBRARY_PATH" \
    PATH="/usr/local/bin:$PATH"
RUN mkdir -p /scripts /backup-data /home/node/.n8n && \
    chown -R node:node /home/node/.n8n /scripts /backup-data
COPY --chown=node:node scripts/ /scripts/
RUN sed -i 's/\r$//' /scripts/*.sh && chmod 0755 /scripts/*.sh
USER node
WORKDIR /home/node
ENTRYPOINT ["sh", "/scripts/start.sh"]
