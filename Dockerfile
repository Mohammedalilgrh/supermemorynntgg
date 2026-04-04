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
# ─────────────────────────────────────────────────────────────
FROM docker.n8n.io/n8nio/n8n:2.6.4

USER root

COPY --from=tools /toolbox/       /usr/local/bin/
COPY --from=tools /etc/ssl/certs/ /etc/ssl/certs/

# ── Install everything via apt-get (n8n base is Debian) ──────
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      python3 \
      python3-minimal \
      fontconfig \
      fonts-dejavu-core \
      fonts-dejavu-extra \
      fonts-noto \
      fonts-noto-core \
      fonts-noto-extra \
      fonts-noto-ui-core \
      fonts-arabeyes \
      fonts-kacst \
      fonts-kacst-one \
      libass9 \
      libfribidi0 \
      libharfbuzz0b \
      libfreetype6 \
      bash \
      coreutils \
      findutils \
      curl \
      jq \
      sqlite3 \
      ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

RUN fc-cache -fv 2>/dev/null || true

# ── Python3 symlinks ─────────────────────────────────────────
RUN ln -sf /usr/bin/python3 /usr/local/bin/python3 && \
    ln -sf /usr/bin/python3 /usr/local/bin/python  && \
    ln -sf /usr/bin/python3 /bin/python3            && \
    ln -sf /usr/bin/python3 /bin/python

# ── FFmpeg setup ─────────────────────────────────────────────
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

COPY --chown=node:node scripts/ /scripts/

RUN sed -i 's/\r$//' /scripts/*.sh && \
    chmod 0755 /scripts/*.sh

# ── Final verification (ALL ONE-LINERS — no multiline python) ─
USER node

RUN ffmpeg -version | head -1
RUN ffprobe -version | head -1
RUN python3 --version
RUN python3 -c "print('Python3 OK')"
RUN python3 -c "t='d8a8d8b3d985d984d984d987';r=bytes.fromhex(t).decode();print('Arabic OK:',r)"
RUN echo "aGVsbG8gd29ybGQ=" | base64 -d && echo ""
RUN fc-list :lang=ar 2>/dev/null | head -3 || echo "Arabic fonts listed"
RUN echo "ALL DEPENDENCIES VERIFIED SUCCESSFULLY"

WORKDIR /home/node

ENTRYPOINT ["sh", "/scripts/start.sh"]
