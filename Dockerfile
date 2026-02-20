FROM alpine:3.20 AS tools

RUN apk add --no-cache \
    curl jq sqlite tar gzip coreutils findutils \
    bind-tools netcat-openbsd procps

# نأخذ كل الأوامر اللي ممكن نحتاجها
RUN mkdir -p /toolbox && \
    for cmd in curl jq sqlite3 tar gzip split du stat find \
               awk sed grep head tail cut tr wc date sleep \
               mkdir rm cp mv basename expr sha256sum; do \
      p="$(which $cmd)" && cp "$p" /toolbox/ || true; \
    done

FROM docker.n8n.io/n8nio/n8n:2.7.4

USER root

# ننسخ كل الأدوات من الـ stage الأولى
COPY --from=tools /toolbox/ /usr/local/bin/
COPY --from=tools /usr/lib/ /usr/local/lib/
COPY --from=tools /lib/ /usr/local/lib2/
COPY --from=tools /etc/ssl/certs/ /etc/ssl/certs/

ENV LD_LIBRARY_PATH="/usr/local/lib:/usr/local/lib2:$LD_LIBRARY_PATH"
ENV PATH="/usr/local/bin:$PATH"

# المجلدات الآمنة + TMP داخل home
RUN mkdir -p /home/node/tmp /scripts /backup-data && \
    chown -R node:node /home/node/.n8n /home/node/tmp /scripts /backup-data && \
    apk add --no-cache ca-certificates

# الحل السحري لـ Render Free
ENV TMPDIR=/home/node/tmp
ENV TMP=/home/node/tmp
ENV TEMP=/home/node/tmp
ENV NODE_OPTIONS="--max-old-space-size=512"

COPY --chown=node:node scripts/ /scripts/

RUN find /scripts -name "*.sh" -exec chmod +x {} \; && \
    find /scripts -name "*.sh" -exec sed -i 's/\r$//' {} \;

USER node
WORKDIR /home/node

ENTRYPOINT ["sh", "/scripts/start.sh"]
