#!/bin/bash

# ============================================
# Viral Video Compiler - Professional Edition
# يدعم أي عدد من المقاطع، يختار الأفضل، يعالج بذكاء
# متوافق مع Render Free Tier + Cloudflare R2
# ============================================

set -e

# ========== قراءة الإعدادات من n8n ==========
# كل الإعدادات تجي من Function Node في n8n

# إعدادات عامة
MAX_VIDEOS="${MAX_VIDEOS:-10}"           # كم مقطع تريد (يحدده n8n)
CLIP_DURATION="${CLIP_DURATION:-6}"       # كل مقطع كم ثانية
MAX_TOTAL_DURATION="${MAX_TOTAL_DURATION:-40}"  # المقطع النهائي كم ثانية
QUALITY="${QUALITY:-fast}"                # fast / medium / high
EFFECTS="${EFFECTS:-auto}"                # auto / light / cinematic
USE_R2="${USE_R2:-true}"                  # true = R2, false = local

# إعدادات R2
R2_BUCKET="${R2_BUCKET_NAME:-renderram}"
R2_ACCOUNT_ID="${R2_ACCOUNT_ID:-b97f9ba5a3446028430de112d2bd0a61}"
R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"

# ========== إعدادات الجودة ==========
case "$QUALITY" in
    fast)
        CRF=28
        PRESET="ultrafast"
        AUDIO_BITRATE="96k"
        ;;
    medium)
        CRF=23
        PRESET="medium"
        AUDIO_BITRATE="128k"
        ;;
    high)
        CRF=18
        PRESET="slow"
        AUDIO_BITRATE="192k"
        ;;
    *)
        CRF=28
        PRESET="ultrafast"
        AUDIO_BITRATE="96k"
        ;;
esac

# ========== إعدادات التأثيرات ==========
case "$EFFECTS" in
    light)
        FILTER="scale=1080:1920:force_original_aspect_ratio=decrease,pad=1080:1920:(ow-iw)/2:(oh-ih)/2,boxblur=10:2"
        ;;
    cinematic)
        FILTER="scale=1080:1920:force_original_aspect_ratio=decrease,pad=1080:1920:(ow-iw)/2:(oh-ih)/2,boxblur=15:3,eq=saturation=1.2:contrast=1.1:brightness=0.05,drawtext=text='CINEMATIC':fontsize=28:fontcolor=white:x=(w-text_w)/2:y=H-60"
        ;;
    auto|*)
        FILTER="scale=1080:1920:force_original_aspect_ratio=decrease,pad=1080:1920:(ow-iw)/2:(oh-ih)/2,boxblur=12:2,drawtext=text='🔥 VIRAL 🔥':fontsize=32:fontcolor=#FFD700:x=(w-text_w)/2:y=H-80:enable='between(t,5,7)'"
        ;;
esac

# ========== إعدادات متقدمة ==========
TEMP_DIR="/tmp/viral_$$"
OUTPUT_DIR="/tmp/viral_output"
mkdir -p "$TEMP_DIR" "$OUTPUT_DIR"

# ========== Functions ==========
cleanup() {
    echo "🧹 Cleaning up..." >&2
    rm -rf "$TEMP_DIR" 2>/dev/null || true
}

log() {
    echo "[$(date '+%H:%M:%S')] $1" >&2
}

# رفع لـ R2
upload_to_r2() {
    local file="$1"
    local key="$2"
    
    [ "$USE_R2" != "true" ] && return 1
    [ -z "$R2_ACCESS_KEY_ID" ] && return 1
    
    log "📤 Uploading to R2..."
    
    curl -s -X PUT \
        -H "Authorization: AWS ${R2_ACCESS_KEY_ID}:$(echo -n "PUT\n\nvideo/mp4\n\nx-amz-date:$(date -u +%Y%m%dT%H%M%SZ)\n/${R2_BUCKET}/${key}" | openssl sha1 -hmac "${R2_SECRET_ACCESS_KEY}" -binary | base64)" \
        -H "x-amz-date: $(date -u +%Y%m%dT%H%M%SZ)" \
        -H "Content-Type: video/mp4" \
        -T "$file" \
        "${R2_ENDPOINT}/${R2_BUCKET}/${key}" 2>/dev/null && echo "https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com/${R2_BUCKET}/${key}"
}

# معالجة فيديو واحد (بستخدام Streaming)
process_video() {
    local url="$1"
    local id="$2"
    local duration="$3"
    local output="$4"
    
    log "🎬 Processing: $id (${duration}s)"
    
    curl -L "$url" 2>/dev/null | \
    ffmpeg -i pipe:0 \
           -t "$duration" \
           -vf "$FILTER" \
           -c:v libx264 -preset "$PRESET" -crf "$CRF" \
           -c:a aac -b:a "$AUDIO_BITRATE" \
           -movflags +faststart \
           -y "$output" 2>/dev/null
    
    [ -f "$output" ] && [ -s "$output" ]
    return $?
}

# دمج المقاطع
merge_clips() {
    local output="$1"
    shift
    local clips=("$@")
    
    [ ${#clips[@]} -eq 0 ] && return 1
    
    log "📀 Merging ${#clips[@]} clips..."
    
    local list="$TEMP_DIR/list.txt"
    > "$list"
    for clip in "${clips[@]}"; do
        echo "file '$clip'" >> "$list"
    done
    
    ffmpeg -f concat -safe 0 -i "$list" \
           -c:v libx264 -preset "$PRESET" -crf "$CRF" \
           -c:a aac -b:a "$AUDIO_BITRATE" \
           -movflags +faststart \
           -y "$output" 2>/dev/null
    
    [ -f "$output" ] && [ -s "$output" ]
}

# ========== Main ==========
trap cleanup EXIT

log "════════════════════════════════════════════"
log "🎬 Viral Video Compiler - Professional"
log "════════════════════════════════════════════"

# قراءة البيانات
JSON_INPUT=$(cat)
TOTAL=$(echo "$JSON_INPUT" | jq '.videos | length' 2>/dev/null || echo "0")

[ "$TOTAL" -eq 0 ] && { echo '{"error":"No videos"}'; exit 1; }

log "📊 Found $TOTAL videos from Pexels"
log "⚙️  Settings: ${MAX_VIDEOS}videos | ${CLIP_DURATION}s/clip | ${MAX_TOTAL_DURATION}s max"
log "🎨 Quality: $QUALITY | Effects: $EFFECTS"

# حساب العدد المناسب
MAX_CLIPS=$(( MAX_TOTAL_DURATION / CLIP_DURATION ))
[ $MAX_CLIPS -lt 1 ] && MAX_CLIPS=1
[ $MAX_CLIPS -gt $MAX_VIDEOS ] && MAX_CLIPS=$MAX_VIDEOS
[ $MAX_CLIPS -gt $TOTAL ] && MAX_CLIPS=$TOTAL

log "🎯 Target: ${MAX_CLIPS} clips → ${MAX_TOTAL_DURATION}s max"

# معالجة المقاطع
CLIPS=()
SUCCESS=0
TOTAL_DURATION=0

for i in $(seq 0 $((MAX_CLIPS - 1))); do
    URL=$(echo "$JSON_INPUT" | jq -r ".videos[$i].video_files[0].link" 2>/dev/null)
    ID=$(echo "$JSON_INPUT" | jq -r ".videos[$i].id" 2>/dev/null)
    
    [ "$URL" = "null" ] && continue
    
    # احسب المدة المتبقية
    REMAINING=$(( MAX_TOTAL_DURATION - TOTAL_DURATION ))
    THIS_DURATION=$(( CLIP_DURATION < REMAINING ? CLIP_DURATION : REMAINING ))
    [ $THIS_DURATION -lt 1 ] && break
    
    CLIP_FILE="$TEMP_DIR/clip_${ID}.mp4"
    
    if process_video "$URL" "$ID" "$THIS_DURATION" "$CLIP_FILE"; then
        CLIPS+=("$CLIP_FILE")
        TOTAL_DURATION=$((TOTAL_DURATION + THIS_DURATION))
        ((SUCCESS++))
        log "✅ Clip $SUCCESS: ${THIS_DURATION}s (Total: ${TOTAL_DURATION}s)"
    fi
    
    sleep 1
done

log "✅ Processed $SUCCESS clips | ${TOTAL_DURATION}s total"

# إنشاء المقطع النهائي
FINAL_FILE=""
R2_URL=""
SIZE_MB=0

if [ ${#CLIPS[@]} -gt 0 ]; then
    FINAL_FILE="$OUTPUT_DIR/viral_$(date +%s).mp4"
    
    if [ ${#CLIPS[@]} -eq 1 ]; then
        cp "${CLIPS[0]}" "$FINAL_FILE"
    else
        merge_clips "$FINAL_FILE" "${CLIPS[@]}"
    fi
    
    if [ -f "$FINAL_FILE" ]; then
        SIZE_MB=$(stat -c%s "$FINAL_FILE" 2>/dev/null | awk '{print int($1/1024/1024)}')
        log "📀 Created: ${SIZE_MB}MB | ${TOTAL_DURATION}s"
        
        # رفع لـ R2
        if [ "$USE_R2" = "true" ]; then
            R2_KEY="compilation/$(date +%s)_${SUCCESS}clips.mp4"
            R2_URL=$(upload_to_r2 "$FINAL_FILE" "$R2_KEY")
            [ -n "$R2_URL" ] && log "✅ Uploaded to R2" && rm -f "$FINAL_FILE"
        fi
    fi
fi

# ========== Output JSON ==========
cat << EOF
{
    "status": "success",
    "stats": {
        "pexels_videos": $TOTAL,
        "clips_used": $SUCCESS,
        "total_duration": $TOTAL_DURATION,
        "target_duration": $MAX_TOTAL_DURATION,
        "size_mb": $SIZE_MB
    },
    "config": {
        "max_videos": $MAX_VIDEOS,
        "clip_duration": $CLIP_DURATION,
        "quality": "$QUALITY",
        "effects": "$EFFECTS",
        "use_r2": $USE_R2
    },
    "output": {
        "local_file": "$FINAL_FILE",
        "r2_url": "$R2_URL"
    },
    "ram_mb": $(ps -o rss= -p $$ | tr -d ' '),
    "timestamp": "$(date -Iseconds)"
}
EOF
