FROM alpine:3.20 AS tools

# 1️⃣ Install dependencies INCLUDING libass and fonts
RUN apk add --no-cache \
      curl jq sqlite tar gzip xz \
      coreutils findutils ca-certificates \
      fontconfig ttf-dejavu libass \
      && mkdir -p /toolbox /fonts /libs && \
      for cmd in curl jq sqlite3 split sha256sum \
                 stat du sort tail awk xargs find \
                 wc cut tr gzip tar cat date sleep \
                 mkdir rm ls grep sed head touch \
                 cp mv basename expr; do \
        p="$(which $cmd 2>/dev/null)" && \
          [ -f "$p" ] && cp "$p" /toolbox/ || true; \
      done && \
      cp -r /usr/share/fonts /fonts/ && \
      cp -r /etc/fonts /fonts/ && \
      cp /usr/lib/libass.so* /libs/ 2>/dev/null || true && \
      cp /usr/lib/libfribidi.so* /libs/ 2>/dev/null || true && \
      cp /usr/lib/libharfbuzz.so* /libs/ 2>/dev/null || true && \
      cp /usr/lib/libfreetype.so* /libs/ 2>/dev/null || true && \
      cp /usr/lib/libfontconfig.so* /libs/ 2>/dev/null || true

# 2️⃣ Download and setup FFMPEG static
RUN curl -L -o /tmp/ffmpeg.tar.xz https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz && \
    tar -xJf /tmp/ffmpeg.tar.xz -C /tmp/ && \
    cp /tmp/ffmpeg-*-static/ffmpeg /toolbox/ && \
    cp /tmp/ffmpeg-*-static/ffprobe /toolbox/ && \
    rm -rf /tmp/ffmpeg-*-static /tmp/ffmpeg.tar.xz

FROM docker.n8n.io/n8nio/n8n:2.6.2

USER root

# 3️⃣ Copy tools + libs + fonts
COPY --from=tools /toolbox/        /usr/local/bin/
COPY --from=tools /libs/           /usr/local/lib/
COPY --from=tools /fonts/          /usr/share/fonts/
COPY --from=tools /etc/ssl/certs/  /etc/ssl/certs/

# 4️⃣ Set environment variables for libs and fonts
ENV LD_LIBRARY_PATH="/usr/local/lib:$LD_LIBRARY_PATH"
ENV FONTCONFIG_PATH="/usr/share/fonts/etc/fonts"
ENV PATH="/usr/local/bin:$PATH"

# 5️⃣ Update font cache
RUN fc-cache -fv && \
    mkdir -p /scripts /backup-data /home/node/.n8n && \
    chown -R node:node /home/node/.n8n /scripts /backup-data

USER node

RUN cd /home/node/.n8n && \
    mkdir -p nodes && \
    cd nodes && \
    npm init -y 2>/dev/null && \
    npm install @mookielianhd/n8n-nodes-instagram 2>/dev/null || true

USER root
COPY --chown=node:node scripts/ /scripts/
RUN sed -i 's/\r$//' /scripts/*.sh && chmod 0755 /scripts/*.sh
USER node

WORKDIR /home/node
ENTRYPOINT ["sh", "/scripts/start.sh"]
