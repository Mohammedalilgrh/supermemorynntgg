#!/bin/bash

# Viral Video Processor for n8n with Cloudflare R2
# This script processes videos into 9:16 format with viral effects
# Stores all files in Cloudflare R2 bucket

set -e

# Get parameters from n8n
VIDEO_URL="$1"
VIDEO_ID="$2"
OUTPUT_DIR="${3:-/tmp/viral_output}"

# ========== Cloudflare R2 Configuration ==========
R2_ACCOUNT_ID="${R2_ACCOUNT_ID:-b97f9ba5a3446028430de112d2bd0a61}"
R2_ACCESS_KEY_ID="${R2_ACCESS_KEY_ID:-}"
R2_SECRET_ACCESS_KEY="${R2_SECRET_ACCESS_KEY:-}"
R2_BUCKET_NAME="${R2_BUCKET_NAME:-renderram}"
R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"

# Function to upload file to R2
upload_to_r2() {
    local local_file="$1"
    local remote_key="$2"
    local content_type="${3:-video/mp4}"
    
    if [ -z "$R2_ACCESS_KEY_ID" ] || [ -z "$R2_SECRET_ACCESS_KEY" ]; then
        echo "⚠️ R2 credentials not set, skipping upload" >> "$LOG_FILE"
        return 1
    fi
    
    echo "   Uploading to R2: $remote_key" >> "$LOG_FILE"
    
    curl -s -X PUT \
        -H "Authorization: AWS ${R2_ACCESS_KEY_ID}:$(echo -n "PUT\n\n${content_type}\n\nx-amz-date:$(date -u +%Y%m%dT%H%M%SZ)\n/${R2_BUCKET_NAME}/${remote_key}" | openssl sha1 -hmac "${R2_SECRET_ACCESS_KEY}" -binary | base64)" \
        -H "x-amz-date: $(date -u +%Y%m%dT%H%M%SZ)" \
        -H "Content-Type: ${content_type}" \
        -T "$local_file" \
        "${R2_ENDPOINT}/${R2_BUCKET_NAME}/${remote_key}" 2>> "$LOG_FILE"
    
    return $?
}

# Function to generate R2 public URL
get_r2_url() {
    local remote_key="$1"
    echo "https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com/${R2_BUCKET_NAME}/${remote_key}"
}

# ========== End R2 Configuration ==========

# Validate input
if [ -z "$VIDEO_URL" ] || [ "$VIDEO_URL" = "null" ] || [ "$VIDEO_URL" = "undefined" ]; then
    echo '{"error":"No video URL provided","status":"failed"}'
    exit 1
fi

# Generate ID if not provided
if [ -z "$VIDEO_ID" ] || [ "$VIDEO_ID" = "null" ]; then
    VIDEO_ID="video_$(date +%s)"
fi

# Create directories
mkdir -p "$OUTPUT_DIR"
TEMP_DIR="/tmp/ffmpeg-temp/viral_${VIDEO_ID}"
mkdir -p "$TEMP_DIR"

# File paths
INPUT_FILE="$TEMP_DIR/input.mp4"
OUTPUT_FILE="$OUTPUT_DIR/viral_${VIDEO_ID}.mp4"
SUBTITLE_FILE="$TEMP_DIR/subtitles.srt"
LOG_FILE="/tmp/ffmpeg-temp/ffmpeg_${VIDEO_ID}.log"

echo "Processing video ID: $VIDEO_ID" > "$LOG_FILE"
echo "URL: $VIDEO_URL" >> "$LOG_FILE"
echo "R2 Bucket: $R2_BUCKET_NAME" >> "$LOG_FILE"
echo "R2 Endpoint: $R2_ENDPOINT" >> "$LOG_FILE"

# Download video
echo "Downloading video..." >> "$LOG_FILE"
if ! curl -L -o "$INPUT_FILE" "$VIDEO_URL" -s --fail --show-error 2>> "$LOG_FILE"; then
    echo '{"error":"Failed to download video","video_id":"'"$VIDEO_ID"'","status":"failed"}'
    rm -rf "$TEMP_DIR"
    exit 1
fi

# Check download
if [ ! -s "$INPUT_FILE" ]; then
    echo '{"error":"Downloaded file is empty","video_id":"'"$VIDEO_ID"'","status":"failed"}'
    rm -rf "$TEMP_DIR"
    exit 1
fi

# Get video duration and dimensions
DURATION=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$INPUT_FILE" 2>/dev/null | cut -d. -f1)
DURATION=${DURATION:-10}

WIDTH=$(ffprobe -v error -select_streams v:0 -show_entries stream=width -of default=noprint_wrappers=1:nokey=1 "$INPUT_FILE" 2>/dev/null)
HEIGHT=$(ffprobe -v error -select_streams v:0 -show_entries stream=height -of default=noprint_wrappers=1:nokey=1 "$INPUT_FILE" 2>/dev/null)

echo "Duration: $DURATION seconds" >> "$LOG_FILE"
echo "Original: ${WIDTH}x${HEIGHT}" >> "$LOG_FILE"

# Generate viral subtitles with Arabic support
cat > "$SUBTITLE_FILE" << 'EOF'
1
00:00:00,000 --> 00:00:03,000
🔥 VIRAL MOMENT 🔥

2
00:00:03,000 --> 00:00:06,000
✨ CINEMATIC 4K ✨

3
00:00:06,000 --> 00:00:09,000
💚 LIKE & SUBSCRIBE 💚

4
00:00:09,000 --> 00:00:12,000
🌟 AMAZING NATURE 🌟

5
00:00:12,000 --> 00:00:15,000
🎬 WATCH TILL THE END 🎬
EOF

# Process video with FFmpeg for viral 9:16 format
echo "Processing video with FFmpeg..." >> "$LOG_FILE"

ffmpeg -i "$INPUT_FILE" \
       -filter_complex "\
           [0:v]scale=1080:1920:force_original_aspect_ratio=decrease, \
           pad=1080:1920:(ow-iw)/2:(oh-ih)/2, \
           split=3[main][blur][sub]; \
           [blur]scale=1080:1920,boxblur=20:5[blurred]; \
           [blurred][main]overlay=(W-w)/2:(H-h)/2[v1]; \
           [v1]eq=saturation=1.2:contrast=1.1:brightness=0.05[v2]; \
           [v2]subtitles='$SUBTITLE_FILE':force_style='FontName=DejaVu Sans,FontSize=48,PrimaryColour=&H00FFFF00,OutlineColour=&H00000000,Outline=3,Shadow=1,BorderStyle=3,Alignment=10', \
           drawtext=text='VIDEO ID: ${VIDEO_ID}':fontsize=16:fontcolor=white:x=10:y=10:enable='lt(t,2)', \
           drawtext=text='%{pts\:hms}':fontsize=14:fontcolor=white:x=w-90:y=10:enable='lt(t,2)', \
           drawtext=text='🔥 VIRAL 🔥':fontsize=36:fontcolor=#FFD700:borderw=2:bordercolor=black:x=(w-text_w)/2:y=H-80:enable='between(t,$DURATION-2,$DURATION)', \
           drawtext=text='▓':fontsize=20:fontcolor=#FFD700:x=50:y=H-50:enable='between(t,0,$DURATION)'[v3] \
       " \
       -c:v libx264 \
       -preset ultrafast \
       -crf 18 \
       -pix_fmt yuv420p \
       -r 30 \
       -c:a aac \
       -b:a 128k \
       -movflags +faststart \
       -y \
       "$OUTPUT_FILE" 2>> "$LOG_FILE"

# Check processing result
if [ -f "$OUTPUT_FILE" ] && [ -s "$OUTPUT_FILE" ]; then
    FILE_SIZE=$(stat -c%s "$OUTPUT_FILE" 2>/dev/null || stat -f%z "$OUTPUT_FILE" 2>/dev/null)
    FILE_SIZE_MB=$((FILE_SIZE / 1024 / 1024))
    
    echo "✅ Video processed successfully: ${FILE_SIZE_MB}MB" >> "$LOG_FILE"
    
    # ========== Upload to Cloudflare R2 ==========
    R2_KEY="processed/${VIDEO_ID}_$(date +%s).mp4"
    echo "Uploading to R2: $R2_KEY" >> "$LOG_FILE"
    
    if upload_to_r2 "$OUTPUT_FILE" "$R2_KEY" "video/mp4"; then
        R2_URL=$(get_r2_url "$R2_KEY")
        echo "✅ Uploaded to R2: $R2_URL" >> "$LOG_FILE"
        
        # Also upload input to temp/ for backup (optional)
        TEMP_R2_KEY="temp/${VIDEO_ID}_$(date +%s).mp4"
        upload_to_r2 "$INPUT_FILE" "$TEMP_R2_KEY" "video/mp4" 2>/dev/null || true
        
        # Output JSON for n8n with R2 URL
        cat << EOF
{
    "video_id": "$VIDEO_ID",
    "output_file": "$OUTPUT_FILE",
    "r2_url": "$R2_URL",
    "r2_key": "$R2_KEY",
    "size_bytes": $FILE_SIZE,
    "size_mb": $FILE_SIZE_MB,
    "duration": $DURATION,
    "format": "9:16",
    "resolution": "1080x1920",
    "storage": "Cloudflare R2",
    "bucket": "$R2_BUCKET_NAME",
    "status": "success"
}
EOF
    else
        # Fallback: return local file if R2 upload fails
        cat << EOF
{
    "video_id": "$VIDEO_ID",
    "output_file": "$OUTPUT_FILE",
    "size_bytes": $FILE_SIZE,
    "size_mb": $FILE_SIZE_MB,
    "duration": $DURATION,
    "format": "9:16",
    "resolution": "1080x1920",
    "storage": "local",
    "status": "success",
    "warning": "R2 upload failed, file saved locally"
}
EOF
    fi
    # ========== End R2 Upload ==========
    
else
    echo "❌ FFmpeg processing failed" >> "$LOG_FILE"
    cat << EOF
{
    "error": "FFmpeg processing failed",
    "video_id": "$VIDEO_ID",
    "status": "failed",
    "log_file": "$LOG_FILE"
}
EOF
    exit 1
fi

# Cleanup temp files
rm -rf "$TEMP_DIR"
rm -f "$OUTPUT_FILE" 2>/dev/null || true

echo "✅ Cleanup completed" >> "$LOG_FILE"
