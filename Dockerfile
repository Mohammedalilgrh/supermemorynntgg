# ============ Stage 1: download tools (Alpine is OK here) ============
FROM alpine:3.20 AS tools

RUN apk add --no-cache curl ca-certificates tar gzip xz

# Download static ffmpeg (includes ffmpeg + ffprobe)
RUN curl -L -o /tmp/ffmpeg.tar.xz \
      https://johnvansickle.com/ffmpeg/releases/ffmpeg-release-amd64-static.tar.xz && \
    mkdir -p /out && \
    tar -xJf /tmp/ffmpeg.tar.xz -C /tmp && \
    cp /tmp/ffmpeg-*-static/ffmpeg /out/ && \
    cp /tmp/ffmpeg-*-static/ffprobe /out/ && \
    chmod +x /out/ffmpeg /out/ffprobe && \
    rm -rf /tmp/ffmpeg*

# Download Piper
RUN curl -L -o /tmp/piper.tar.gz \
      "https://github.com/rhasspy/piper/releases/download/2023.11.14-2/piper_linux_x86_64.tar.gz" && \
    mkdir -p /out/piper && \
    tar -xzf /tmp/piper.tar.gz -C /out/piper --strip-components=1 && \
    rm -f /tmp/piper.tar.gz && \
    chmod +x /out/piper/piper

# Download voice model
RUN mkdir -p /out/piper-voices && \
    curl -L -o /out/piper-voices/en_GB-vctk-medium.onnx \
      "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/vctk/medium/en_GB-vctk-medium.onnx" && \
    curl -L -o /out/piper-voices/en_GB-vctk-medium.onnx.json \
      "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/vctk/medium/en_GB-vctk-medium.onnx.json"


# ============ Stage 2: n8n runtime (Debian base) ============
FROM docker.n8n.io/n8nio/n8n:2.6.2

USER root

# Install runtime deps on Debian (for fonts/subtitles etc.)
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
      ca-certificates fontconfig \
      fonts-dejavu fonts-noto fonts-noto-core fonts-noto-extra fonts-noto-color-emoji \
      libass9 libfribidi0 libharfbuzz0b libfreetype6 \
    && rm -rf /var/lib/apt/lists/* && \
    fc-cache -fv || true

# Copy ONLY what we need (NO /lib or /usr/lib from Alpine!)
COPY --from=tools /out/ffmpeg   /usr/local/bin/ffmpeg
COPY --from=tools /out/ffprobe  /usr/local/bin/ffprobe
COPY --from=tools /out/piper    /usr/local/piper
COPY --from=tools /out/piper-voices /usr/local/piper-voices

RUN chmod +x /usr/local/bin/ffmpeg /usr/local/bin/ffprobe /usr/local/piper/piper && \
    ln -sf /usr/local/bin/ffmpeg /usr/bin/ffmpeg && \
    ln -sf /usr/local/bin/ffprobe /usr/bin/ffprobe && \
    ln -sf /usr/local/piper/piper /usr/local/bin/piper

ENV PATH="/usr/local/bin:/usr/local/piper:$PATH"
ENV FFMPEG_PATH="/usr/local/bin/ffmpeg"
ENV FFPROBE_PATH="/usr/local/bin/ffprobe"
ENV FFREPORT="file=/tmp/ffreport-%p-%t.log:level=32"
ENV PIPER_MODEL="/usr/local/piper-voices/en_GB-vctk-medium.onnx"
ENV PIPER_SPEAKER="9"

# Temp dirs
RUN mkdir -p /tmp/ffmpeg-temp /tmp/ffmpeg-cache /var/log/ffmpeg /scripts /backup-data /home/node/.n8n && \
    chmod 1777 /tmp /tmp/ffmpeg-temp /tmp/ffmpeg-cache && \
    chmod 755 /var/log/ffmpeg && \
    chown -R node:node /home/node/.n8n /scripts /backup-data /tmp/ffmpeg-temp /tmp/ffmpeg-cache /var/log/ffmpeg

# Simple TTS helper
RUN cat > /usr/local/bin/tts-en << 'EOF'
#!/bin/sh
set -eu
TEXT="${1:-}"
OUTPUT="${2:-/tmp/tts_out.wav}"

[ -n "$TEXT" ] || { echo "Usage: tts-en \"text\" /path/out.wav|out.mp3" >&2; exit 2; }

if echo "$OUTPUT" | grep -qiE '\.mp3$'; then
  TMP_WAV="/tmp/_piper_$$.wav"
  printf "%s" "$TEXT" | piper --model "$PIPER_MODEL" --speaker "$PIPER_SPEAKER" --output_file "$TMP_WAV"
  ffmpeg -y -hide_banner -loglevel error -i "$TMP_WAV" -codec:a libmp3lame -qscale:a 2 "$OUTPUT"
  rm -f "$TMP_WAV"
else
  printf "%s" "$TEXT" | piper --model "$PIPER_MODEL" --speaker "$PIPER_SPEAKER" --output_file "$OUTPUT"
fi
echo "Done: $OUTPUT"
EOF
RUN chmod +x /usr/local/bin/tts-en

# Install your community node
USER node
RUN cd /home/node/.n8n && mkdir -p nodes && cd nodes && \
    npm init -y >/dev/null 2>&1 && \
    npm install @mookielianhd/n8n-nodes-instagram || true

USER root
COPY --chown=node:node scripts/ /scripts/
RUN sed -i 's/\r$//' /scripts/*.sh 2>/dev/null || true && chmod 0755 /scripts/*.sh

# Final runtime sanity check (important: show errors, don't hide)
USER node
RUN ffmpeg -version && ffprobe -version && \
    echo "Hello Piper" | piper --model "$PIPER_MODEL" --speaker "$PIPER_SPEAKER" --output_file /tmp/test_piper.wav && \
    ls -lh /tmp/test_piper.wav

WORKDIR /home/node
ENTRYPOINT ["sh", "/scripts/start.sh"]
