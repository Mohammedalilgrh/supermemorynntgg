FROM alpine:3.20 AS tools

RUN apk add --no-cache \
      curl jq sqlite tar gzip xz \
      coreutils findutils ca-certificates \
      fontconfig ttf-dejavu font-noto font-noto-arabic \
      font-noto-extra font-arabic-misc fonts-liberation \
      libass fribidi harfbuzz freetype libstdc++ \
      libgcc libgomp zlib expat && \
    mkdir -p /toolbox && \
    for cmd in curl jq sqlite3 split sha256sum \
               stat du sort tail awk xargs find \
               wc cut tr gzip tar cat date sleep \
               mkdir rm ls grep sed head touch \
               cp mv basename expr fc-cache fc-list; do \
      p="$(which $cmd 2>/dev/null)" && \
        [ -f "$p" ] && cp "$p" /toolbox/ || true; \
    done

# Copy font libraries and configs
RUN mkdir -p /toolbox/fonts /toolbox/fontconfig && \
    cp -r /usr/share/fonts/* /toolbox/fonts/ 2>/dev/null || true && \
    cp -r /etc/fonts/* /toolbox/fontconfig/ 2>/dev/null || true && \
    fc-cache -fv

# Download FFmpeg static with all codecs
RUN curl -L -o /tmp/ffmpeg.tar.xz https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz && \
    tar -xJf /tmp/ffmpeg.tar.xz -C /tmp/ && \
    cp /tmp/ffmpeg-*-static/ffmpeg /toolbox/ && \
    cp /tmp/ffmpeg-*-static/ffprobe /toolbox/ && \
    cp /tmp/ffmpeg-*-static/qt-faststart /toolbox/ 2>/dev/null || true && \
    rm -rf /tmp/ffmpeg-*-static /tmp/ffmpeg.tar.xz

FROM docker.n8n.io/n8nio/n8n:2.6.2

USER root

# Install minimal runtime dependencies
RUN apk add --no-cache \
    fontconfig \
    ttf-dejavu \
    font-noto \
    font-noto-arabic \
    font-noto-extra \
    font-arabic-misc \
    fonts-liberation \
    libass \
    fribidi \
    harfbuzz \
    freetype \
    libstdc++ \
    libgcc \
    libgomp \
    zlib \
    expat \
    gcompat

# Copy tools and libraries
COPY --from=tools /toolbox/        /usr/local/bin/
COPY --from=tools /usr/lib/        /usr/local/lib/
COPY --from=tools /lib/            /usr/local/lib2/
COPY --from=tools /etc/ssl/certs/  /etc/ssl/certs/
COPY --from=tools /toolbox/fonts/  /usr/share/fonts/
COPY --from=tools /toolbox/fontconfig/ /etc/fonts/

# Set up environment
ENV LD_LIBRARY_PATH="/usr/local/lib:/usr/local/lib2:/usr/lib:/lib:$LD_LIBRARY_PATH"
ENV PATH="/usr/local/bin:$PATH"
ENV FONTCONFIG_PATH="/etc/fonts"
ENV FONTCONFIG_FILE="/etc/fonts/fonts.conf"

# FFmpeg environment variables
ENV FFMPEG_PATH="/usr/local/bin/ffmpeg"
ENV FFPROBE_PATH="/usr/local/bin/ffprobe"
ENV FFREPORT="file=/tmp/ffreport-%p-%t.log:level=32"

# Arabic text rendering environment
ENV LANG="en_US.UTF-8"
ENV LC_ALL="en_US.UTF-8"
ENV FONTCONFIG_CACHE="/tmp/fontconfig-cache"

# Create necessary directories
RUN mkdir -p /tmp/ffmpeg-temp /tmp/ffmpeg-cache /var/log/ffmpeg \
             /tmp/fontconfig-cache /home/node/.fontconfig && \
    chmod 1777 /tmp/ffmpeg-temp /tmp/ffmpeg-cache /tmp /tmp/fontconfig-cache && \
    chmod 755 /var/log/ffmpeg

# Make binaries executable
RUN chmod +x /usr/local/bin/ffmpeg /usr/local/bin/ffprobe && \
    chmod +x /usr/local/bin/qt-faststart 2>/dev/null || true

# Create symlinks for compatibility
RUN ln -sf /usr/local/bin/ffmpeg /usr/bin/ffmpeg && \
    ln -sf /usr/local/bin/ffprobe /usr/bin/ffprobe && \
    ln -sf /usr/local/bin/ffmpeg /bin/ffmpeg && \
    ln -sf /usr/local/bin/ffprobe /bin/ffprobe

# Update font cache
RUN fc-cache -fv && \
    fc-list :lang=ar > /tmp/arabic-fonts.txt

# Create directories for n8n
RUN mkdir -p /scripts /backup-data /home/node/.n8n && \
    chown -R node:node /home/node/.n8n /scripts /backup-data \
                       /tmp/ffmpeg-temp /tmp/ffmpeg-cache \
                       /var/log/ffmpeg /tmp/fontconfig-cache \
                       /home/node/.fontconfig

# Test FFmpeg with Arabic text capability
RUN /usr/local/bin/ffmpeg -version && \
    /usr/local/bin/ffprobe -version && \
    /usr/local/bin/ffmpeg -filters 2>&1 | grep -E "(drawtext|subtitles|ass)" && \
    echo "Available Arabic fonts:" && \
    fc-list :lang=ar | head -10

USER node

# Install Instagram nodes for n8n
RUN cd /home/node/.n8n && \
    mkdir -p nodes && \
    cd nodes && \
    npm init -y 2>/dev/null && \
    npm install @mookielianhd/n8n-nodes-instagram 2>/dev/null || true

USER root

# Copy and prepare scripts
COPY --chown=node:node scripts/ /scripts/

RUN sed -i 's/\r$//' /scripts/*.sh && \
    chmod 0755 /scripts/*.sh

# Final verification as node user
USER node

RUN echo "=== Final FFmpeg + Arabic Text Verification ===" && \
    ffmpeg -version | head -3 && \
    ffprobe -version | head -3 && \
    echo "Available Arabic fonts:" && \
    fc-list :lang=ar | head -5 && \
    echo "Text rendering filters available:" && \
    ffmpeg -filters 2>&1 | grep -E "(drawtext|subtitles)" && \
    echo "=== Verification Complete ==="

WORKDIR /home/node

ENTRYPOINT ["sh", "/scripts/start.sh"]
