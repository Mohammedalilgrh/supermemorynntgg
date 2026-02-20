FROM docker.n8n.io/n8nio/n8n:2.7.4

USER root

COPY --from=alpine:3.20 /usr/bin/curl /usr/bin/curl
COPY --from=alpine:3.20 /usr/bin/jq /usr/bin/jq
COPY --from=alpine:3.20 /usr/bin/sqlite3 /usr/bin/sqlite3
COPY --from=alpine:3.20 /bin/tar /bin/tar
COPY --from=alpine:3.20 /bin/gzip /bin/gzip
COPY --from=alpine:3.20 /usr/bin/split /usr/bin/split
COPY --from=alpine:3.20 /usr/bin/du /usr/bin/du
COPY --from=alpine:3.20 /usr/bin/stat /usr/bin/stat

RUN mkdir -p /home/node/tmp /scripts /backup-data && \
    chown -R node:node /home/node/.n8n /home/node/tmp /scripts /backup-data && \
    apk add --no-cache coreutils findutils

ENV TMPDIR=/home/node/tmp
ENV TMP=/home/node/tmp
ENV TEMP=/home/node/tmp
ENV NODE_OPTIONS="--max-old-space-size=512"

COPY --chown=node:node scripts/ /scripts/
RUN find /scripts -name '*.sh' -exec chmod 755 {} \; && \
    find /scripts -name '*.sh' -exec sed -i 's/\r$//' {} \;

USER node
WORKDIR /home/node

ENTRYPOINT ["sh", "/scripts/start.sh"]
