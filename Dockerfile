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

FROM docker.n8n.io/n8nio/n8n:2.6.2

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
# ========== CREATE LIGHTWEIGHT TTS API ==========
RUN cat > /opt/tts-api/app.py <<'EOFPYTHON'
from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from pydantic import BaseModel
import edge_tts
import asyncio
import os
import uuid
from pathlib import Path

app = FastAPI()

# Create temp directory
TEMP_DIR = Path("/tmp/tts")
TEMP_DIR.mkdir(exist_ok=True)

class TTSRequest(BaseModel):
    text: str
    voice: str = "en-US-AriaNeural"  # Default English female
    rate: str = "+0%"  # Speed: -50% to +50%
    pitch: str = "+0Hz"  # Pitch adjustment

# Best voices for English and Arabic
VOICES = {
    # English voices
    "aria": "en-US-AriaNeural",  # Female, natural
    "guy": "en-US-GuyNeural",    # Male, natural
    "jenny": "en-US-JennyNeural", # Female, friendly
    "davis": "en-US-DavisNeural", # Male, professional
    
    # Arabic voices
    "salma": "ar-SA-SalmaNeural",  # Female Saudi
    "hamed": "ar-SA-HamedNeural",  # Male Saudi
    "zariyah": "ar-SA-ZariyahNeural", # Female Saudi
    "layla": "ar-EG-SalmaNeural",  # Female Egyptian
    "shakir": "ar-EG-ShakirNeural" # Male Egyptian
}

@app.post("/tts")
async def text_to_speech(request: TTSRequest):
    try:
        # Get voice name
        voice = VOICES.get(request.voice.lower(), request.voice)
        
        # Generate unique filename
        filename = f"{uuid.uuid4()}.mp3"
        filepath = TEMP_DIR / filename
        
        # Generate speech using edge-tts
        communicate = edge_tts.Communicate(
            text=request.text,
            voice=voice,
            rate=request.rate,
            pitch=request.pitch
        )
        
        await communicate.save(str(filepath))
        
        # Return the audio file
        return FileResponse(
            path=filepath,
            media_type="audio/mpeg",
            filename=filename,
            background=cleanup_file(filepath)
        )
    
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

async def cleanup_file(filepath: Path):
    """Delete file after sending"""
    await asyncio.sleep(10)  # Wait 10 seconds
    try:
        if filepath.exists():
            filepath.unlink()
    except:
        pass

@app.get("/voices")
async def list_voices():
    """List all available voices"""
    return {
        "available_voices": VOICES,
        "all_edge_voices": await edge_tts.list_voices()
    }

@app.get("/health")
async def health():
    return {"status": "healthy", "service": "Edge-TTS API"}

# Cleanup old files on startup
@app.on_event("startup")
async def startup_cleanup():
    for f in TEMP_DIR.glob("*.mp3"):
        try:
            f.unlink()
        except:
            pass

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=9871)
EOFPYTHON

# ========== CREATE SUPERVISOR CONFIG ==========
RUN cat > /etc/supervisord.conf <<'EOFSUPER'
[supervisord]
nodaemon=true
user=root
logfile=/var/log/supervisor/supervisord.log
pidfile=/var/run/supervisord.pid

[program:tts-api]
command=python3 /opt/tts-api/app.py
directory=/opt/tts-api
user=node
autostart=true
autorestart=true
stderr_logfile=/var/log/supervisor/tts.err.log
stdout_logfile=/var/log/supervisor/tts.out.log
environment=HOME="/home/node",USER="node"

[program:n8n]
command=sh /scripts/start.sh
user=root
autostart=true
autorestart=true
stderr_logfile=/var/log/supervisor/n8n.err.log
stdout_logfile=/var/log/supervisor/n8n.out.log
EOFSUPER

USER node
RUN python3 --version && edge-tts --version

WORKDIR /home/node

EXPOSE 5678 9871

USER root

ENTRYPOINT ["/usr/bin/supervisord", "-c", "/etc/supervisord.conf"]
