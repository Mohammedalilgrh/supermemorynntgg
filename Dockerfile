# ─────────────────────────────────────────────────────────────
# STAGE 1: Alpine tools builder
# ─────────────────────────────────────────────────────────────
FROM alpine:3.20 AS tools

RUN apk add --no-cache \
      curl \
      tar \
      xz \
      coreutils \
      findutils \
      ca-certificates

RUN mkdir -p /toolbox && \
    for cmd in \
      curl split sha256sum stat du sort tail \
      awk xargs find wc cut tr cat date sleep \
      mkdir rm ls grep sed head touch cp mv \
      basename expr base64; do \
      p="$(which $cmd 2>/dev/null)" && \
        [ -f "$p" ] && cp "$p" /toolbox/ || true; \
    done

RUN curl -L -o /tmp/ffmpeg.tar.xz \
      https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz && \
    tar -xJf /tmp/ffmpeg.tar.xz -C /tmp/ && \
    cp /tmp/ffmpeg-*-static/ffmpeg  /toolbox/ && \
    cp /tmp/ffmpeg-*-static/ffprobe /toolbox/ && \
    rm -rf /tmp/ffmpeg-*-static /tmp/ffmpeg.tar.xz && \
    /toolbox/ffmpeg -version

# ─────────────────────────────────────────────────────────────
# STAGE 2: Final n8n image
# n8n:2.6.4 is based on node:20-alpine — so we use apk
# ─────────────────────────────────────────────────────────────
FROM docker.n8n.io/n8nio/n8n:2.6.4

USER root

# ── Detect OS and confirm it is Alpine ───────────────────────
RUN cat /etc/os-release

# ── Copy ffmpeg + shell tools from builder stage ─────────────
COPY --from=tools /toolbox/       /usr/local/bin/
COPY --from=tools /etc/ssl/certs/ /etc/ssl/certs/

# ── Install everything via apk (Alpine package manager) ──────
RUN apk add --no-cache \
      python3 \
      py3-pip \
      bash \
      coreutils \
      findutils \
      curl \
      jq \
      sqlite \
      ca-certificates \
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
      zlib \
      expat \
    && python3 --version \
    && echo "apk installs done"

# ── Rebuild font cache ────────────────────────────────────────
RUN fc-cache -fv 2>/dev/null || true

# ── Python3 symlinks ─────────────────────────────────────────
RUN ln -sf /usr/bin/python3 /usr/local/bin/python3 && \
    ln -sf /usr/bin/python3 /usr/local/bin/python  && \
    ln -sf /usr/bin/python3 /bin/python3            && \
    ln -sf /usr/bin/python3 /bin/python

# ── FFmpeg environment ───────────────────────────────────────
ENV FFMPEG_PATH="/usr/local/bin/ffmpeg"
ENV FFPROBE_PATH="/usr/local/bin/ffprobe"
ENV FFREPORT="file=/tmp/ffreport-%p-%t.log:level=32"
ENV PATH="/usr/local/bin:$PATH"

RUN chmod +x /usr/local/bin/ffmpeg /usr/local/bin/ffprobe && \
    ln -sf /usr/local/bin/ffmpeg  /usr/bin/ffmpeg   && \
    ln -sf /usr/local/bin/ffprobe /usr/bin/ffprobe  && \
    ln -sf /usr/local/bin/ffmpeg  /bin/ffmpeg       && \
    ln -sf /usr/local/bin/ffprobe /bin/ffprobe

# ── Directories + permissions ────────────────────────────────
RUN mkdir -p \
      /tmp/ffmpeg-temp \
      /tmp/ffmpeg-cache \
      /var/log/ffmpeg \
      /scripts \
      /backup-data \
      /home/node/.n8n && \
    chmod 1777 /tmp/ffmpeg-temp /tmp/ffmpeg-cache /tmp && \
    chmod 755  /var/log/ffmpeg && \
    chown -R node:node \
      /home/node/.n8n \
      /scripts \
      /backup-data \
      /tmp/ffmpeg-temp \
      /tmp/ffmpeg-cache \
      /var/log/ffmpeg

# ── Install n8n community nodes ──────────────────────────────
USER node

RUN cd /home/node/.n8n && \
    mkdir -p nodes && \
    cd nodes && \
    npm init -y 2>/dev/null && \
    npm install @mookielianhd/n8n-nodes-instagram 2>/dev/null || true

USER root

# ── Copy startup scripts ─────────────────────────────────────
COPY --chown=node:node scripts/ /scripts/

RUN sed -i 's/\r$//' /scripts/*.sh && \
    chmod 0755 /scripts/*.sh

# ── Final verification ───────────────────────────────────────
USER node

RUN ffmpeg  -version | head -1 && echo "ffmpeg OK"
RUN ffprobe -version | head -1 && echo "ffprobe OK"
RUN python3 --version          && echo "python3 OK"
RUN python3 -c "print('Python3 runtime OK')"
RUN python3 -c "t='d8a8d8b3d985d984d984d987';r=bytes.fromhex(t).decode('utf-8');print('Arabic OK:',r)"
RUN echo "aGVsbG8=" | base64 -d && echo "" && echo "base64 OK"
RUN fc-list :lang=ar 2>/dev/null | head -3 || echo "Arabic fonts check done"
RUN echo "ALL VERIFIED OK"

WORKDIR /home/node

ENTRYPOINT ["sh", "/scripts/start.sh"]
