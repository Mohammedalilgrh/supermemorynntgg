# ─────────────────────────────────────────────────────────────
# STAGE 1: Alpine tools builder
# Download ffmpeg static + collect shell tools
# ─────────────────────────────────────────────────────────────
FROM alpine:3.20 AS tools

RUN apk add --no-cache \
      curl \
      tar \
      xz \
      coreutils \
      findutils \
      ca-certificates

# Collect basic shell tools into /toolbox
RUN mkdir -p /toolbox && \
    for cmd in \
      curl split sha256sum stat du sort tail \
      awk xargs find wc cut tr cat date sleep \
      mkdir rm ls grep sed head touch cp mv \
      basename expr base64; do \
      p="$(which $cmd 2>/dev/null)" && \
        [ -f "$p" ] && cp "$p" /toolbox/ || true; \
    done

# Download ffmpeg static binary (amd64)
RUN curl -L -o /tmp/ffmpeg.tar.xz \
      https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz && \
    tar -xJf /tmp/ffmpeg.tar.xz -C /tmp/ && \
    cp /tmp/ffmpeg-*-static/ffmpeg  /toolbox/ && \
    cp /tmp/ffmpeg-*-static/ffprobe /toolbox/ && \
    rm -rf /tmp/ffmpeg-*-static /tmp/ffmpeg.tar.xz && \
    /toolbox/ffmpeg -version

# ─────────────────────────────────────────────────────────────
# STAGE 2: Python3 builder
# Build/collect Python3 from Debian (same OS as n8n base image)
# This is the KEY FIX — get Python from Debian not Alpine
# ─────────────────────────────────────────────────────────────
FROM debian:bookworm-slim AS python-builder

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      python3 \
      python3-minimal \
      libpython3-stdlib \
      libpython3.11-stdlib \
      libpython3.11-minimal \
    && rm -rf /var/lib/apt/lists/*

# Verify python works
RUN python3 --version && \
    python3 -c "print('Python3 build stage OK')"

# ─────────────────────────────────────────────────────────────
# STAGE 3: Final n8n image
# ─────────────────────────────────────────────────────────────
FROM docker.n8n.io/n8nio/n8n:2.6.4

USER root

# ── Copy ffmpeg + shell tools from Alpine stage ──────────────
COPY --from=tools /toolbox/ /usr/local/bin/

# ── Copy SSL certs ───────────────────────────────────────────
COPY --from=tools /etc/ssl/certs/ /etc/ssl/certs/

# ─────────────────────────────────────────────────────────────
# Install ALL dependencies via apt-get (Debian is the base OS)
# This is correct — n8n image is Debian-based
# ─────────────────────────────────────────────────────────────
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      # ── Python3 (THE MAIN FIX) ──────────────────────────
      python3 \
      python3-minimal \
      # ── Font rendering for Arabic subtitles ─────────────
      fontconfig \
      fonts-dejavu-core \
      fonts-dejavu-extra \
      fonts-noto \
      fonts-noto-core \
      fonts-noto-extra \
      fonts-noto-ui-core \
      fonts-noto-ui-extra \
      fonts-arabeyes \
      fonts-kacst \
      fonts-kacst-one \
      # ── Libraries needed by ffmpeg static binary ─────────
      libass9 \
      libfribidi0 \
      libharfbuzz0b \
      libfreetype6 \
      # ── Shell utilities ──────────────────────────────────
      bash \
      coreutils \
      findutils \
      curl \
      jq \
      sqlite3 \
      # ── SSL ──────────────────────────────────────────────
      ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && apt-get clean

# ── Rebuild font cache ────────────────────────────────────────
RUN fc-cache -fv 2>/dev/null || true

# ─────────────────────────────────────────────────────────────
# Python3 symlinks — ensure accessible from all PATH locations
# ─────────────────────────────────────────────────────────────
RUN ln -sf /usr/bin/python3 /usr/local/bin/python3 && \
    ln -sf /usr/bin/python3 /usr/local/bin/python  && \
    ln -sf /usr/bin/python3 /bin/python3            && \
    ln -sf /usr/bin/python3 /bin/python

# ─────────────────────────────────────────────────────────────
# FFmpeg setup
# ─────────────────────────────────────────────────────────────
ENV FFMPEG_PATH="/usr/local/bin/ffmpeg"
ENV FFPROBE_PATH="/usr/local/bin/ffprobe"
ENV FFREPORT="file=/tmp/ffreport-%p-%t.log:level=32"
ENV PATH="/usr/local/bin:$PATH"

RUN chmod +x /usr/local/bin/ffmpeg /usr/local/bin/ffprobe && \
    ln -sf /usr/local/bin/ffmpeg  /usr/bin/ffmpeg   && \
    ln -sf /usr/local/bin/ffprobe /usr/bin/ffprobe  && \
    ln -sf /usr/local/bin/ffmpeg  /bin/ffmpeg        && \
    ln -sf /usr/local/bin/ffprobe /bin/ffprobe

# ─────────────────────────────────────────────────────────────
# Directories + permissions
# ─────────────────────────────────────────────────────────────
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

# ─────────────────────────────────────────────────────────────
# Install n8n community nodes as node user
# ─────────────────────────────────────────────────────────────
USER node

RUN cd /home/node/.n8n && \
    mkdir -p nodes && \
    cd nodes && \
    npm init -y 2>/dev/null && \
    npm install @mookielianhd/n8n-nodes-instagram 2>/dev/null || true

# ─────────────────────────────────────────────────────────────
# Copy startup scripts
# ─────────────────────────────────────────────────────────────
USER root

COPY --chown=node:node scripts/ /scripts/

RUN sed -i 's/\r$//' /scripts/*.sh && \
    chmod 0755 /scripts/*.sh

# ─────────────────────────────────────────────────────────────
# Final verification — run as node user (same as runtime)
# ─────────────────────────────────────────────────────────────
USER node

RUN echo "======================================" && \
    echo "VERIFYING ALL DEPENDENCIES" && \
    echo "======================================" && \
    \
    echo "[1/6] FFmpeg:" && \
    ffmpeg -version | head -1 && \
    \
    echo "[2/6] FFprobe:" && \
    ffprobe -version | head -1 && \
    \
    echo "[3/6] Python3:" && \
    python3 --version && \
    \
    echo "[4/6] Python3 UTF-8 + Arabic decode test:" && \
    python3 -c "
text = 'بِسْمِ اللَّهِ الرَّحْمَٰنِ الرَّحِيمِ'
encoded = text.encode('utf-8')
hex_str = ''.join(f'{b:02x}' for b in encoded)
decoded = bytes.fromhex(hex_str).decode('utf-8')
assert decoded == text, 'Decode mismatch!'
print('Arabic decode OK:', decoded)
" && \
    \
    echo "[5/6] Base64:" && \
    echo "aGVsbG8gd29ybGQ=" | base64 -d && echo "" && \
    \
    echo "[6/6] Arabic fonts:" && \
    fc-list :lang=ar 2>/dev/null | head -3 && \
    \
    echo "======================================" && \
    echo "ALL DEPENDENCIES VERIFIED SUCCESSFULLY" && \
    echo "======================================"

WORKDIR /home/node

ENTRYPOINT ["sh", "/scripts/start.sh"]
