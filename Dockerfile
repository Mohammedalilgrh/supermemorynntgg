FROM alpine:3.20 AS tools

RUN apk add --no-cache \
      curl jq sqlite tar gzip xz \
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

# تحميل ffmpeg static في مرحلة Alpine
RUN curl -L -o /tmp/ffmpeg.tar.xz https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz && \
    tar -xJf /tmp/ffmpeg.tar.xz -C /tmp/ && \
    cp /tmp/ffmpeg-*-static/ffmpeg /toolbox/ && \
    cp /tmp/ffmpeg-*-static/ffprobe /toolbox/ && \
    rm -rf /tmp/ffmpeg-*-static /tmp/ffmpeg.tar.xz

FROM docker.n8n.io/n8nio/n8n:2.15.0

USER root

COPY --from=tools /toolbox/        /usr/local/bin/
COPY --from=tools /usr/lib/        /usr/local/lib/
COPY --from=tools /lib/            /usr/local/lib2/
COPY --from=tools /etc/ssl/certs/  /etc/ssl/certs/

ENV LD_LIBRARY_PATH="/usr/local/lib:/usr/local/lib2:$LD_LIBRARY_PATH"
ENV PATH="/usr/local/bin:$PATH"

# FFmpeg environment variables for full compatibility
ENV FFMPEG_PATH="/usr/local/bin/ffmpeg"
ENV FFPROBE_PATH="/usr/local/bin/ffprobe"
ENV FFREPORT="file=/tmp/ffreport-%p-%t.log:level=32"

# FFmpeg runtime directories
RUN mkdir -p /tmp/ffmpeg-temp /tmp/ffmpeg-cache /var/log/ffmpeg && \
    chmod 1777 /tmp/ffmpeg-temp /tmp/ffmpeg-cache /tmp && \
    chmod 755 /var/log/ffmpeg

# Verify ffmpeg binaries are executable and working
RUN chmod +x /usr/local/bin/ffmpeg /usr/local/bin/ffprobe && \
    /usr/local/bin/ffmpeg -version && \
    /usr/local/bin/ffprobe -version

# Create symlinks for common paths where n8n nodes might look for ffmpeg
RUN ln -sf /usr/local/bin/ffmpeg /usr/bin/ffmpeg && \
    ln -sf /usr/local/bin/ffprobe /usr/bin/ffprobe && \
    ln -sf /usr/local/bin/ffmpeg /bin/ffmpeg && \
    ln -sf /usr/local/bin/ffprobe /bin/ffprobe

# ===== هذا الجزء المهم الناقص - الخطوط والـ fontconfig =====
RUN apk add --no-cache \
    fontconfig \
    ttf-dejavu \
    font-noto \
    font-noto-arabic \
    font-noto-extra \
    libass \
    fribidi \
    harfbuzz \
    freetype \
    libstdc++ \
    libgcc \
    libgomp \
    zlib \
    expat \
    2>/dev/null || true

# تحديث cache الخطوط
RUN fc-cache -fv 2>/dev/null || true

RUN mkdir -p /scripts /backup-data /home/node/.n8n && \
    chown -R node:node /home/node/.n8n /scripts /backup-data

# Ensure node user has access to ffmpeg temp directories
RUN chown -R node:node /tmp/ffmpeg-temp /tmp/ffmpeg-cache /var/log/ffmpeg

USER node

RUN cd /home/node/.n8n && \
    mkdir -p nodes && \
    cd nodes && \
    npm init -y 2>/dev/null && \
    npm install @mookielianhd/n8n-nodes-instagram 2>/dev/null || true

USER root

COPY --chown=node:node scripts/ /scripts/

RUN sed -i 's/\r$//' /scripts/*.sh && \
    chmod 0755 /scripts/*.sh

# Final verification that ffmpeg works for node user
USER node
RUN ffmpeg -version && ffprobe -version && \
    fc-list :lang=ar 2>/dev/null | head -5 || echo "Arabic fonts check done" && \
    echo "FFmpeg installation verified successfully"

WORKDIR /home/node

ENTRYPOINT ["sh", "/scripts/start.sh"]
