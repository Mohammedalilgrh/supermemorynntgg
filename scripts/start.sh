#!/bin/bash
set -eu
umask 077

N8N_DIR="${N8N_DIR:-/home/node/.n8n}"
WORK="${WORK:-/backup-data}"
MONITOR_INTERVAL="${MONITOR_INTERVAL:-60}"
N8N_PORT="${N8N_PORT:-5678}"

mkdir -p "$N8N_DIR" "$WORK" "$WORK/history"
export HOME="/home/node"

: "${TG_BOT_TOKEN:?Set TG_BOT_TOKEN}"
: "${TG_CHAT_ID:?Set TG_CHAT_ID}"
: "${TG_ADMIN_ID:?Set TG_ADMIN_ID}"

TG="https://api.telegram.org/bot${TG_BOT_TOKEN}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

tg_msg() {
  curl -sS --max-time 15 -X POST "${TG}/sendMessage" \
    -d "chat_id=${TG_ADMIN_ID}" \
    -d "parse_mode=HTML" \
    --data-urlencode "text=$1" \
    >/dev/null 2>&1 || true
}

log ""
log "╔══════════════════════════════════════════════╗"
log "║  n8n + Telegram Smart Backup v5.2            ║"
log "╚══════════════════════════════════════════════╝"
log "Node: $(node --version) | n8n: $(n8n --version 2>/dev/null || echo '?')"
log ""

# ── فحص الأدوات ──
ALL_OK=true
for cmd in curl jq sqlite3 tar gzip bash; do
  command -v "$cmd" >/dev/null 2>&1 || { log "❌ missing: $cmd"; ALL_OK=false; }
done
[ "$ALL_OK" = "true" ] || { log "❌ أدوات ناقصة"; exit 1; }
log "✅ كل الأدوات موجودة"

# ── فحص البوت ──
_bot_resp=$(curl -sS --max-time 10 "${TG}/getMe" 2>/dev/null || true)
BOT_OK=$(echo "$_bot_resp" | jq -r '.ok // "false"' 2>/dev/null || echo "false")
BOT_NAME=$(echo "$_bot_resp" | jq -r '.result.username // "?"' 2>/dev/null || echo "?")
if [ "$BOT_OK" = "true" ]; then
  log "✅ البوت: @${BOT_NAME}"
else
  log "⚠️ تحذير: البوت غير متصل"
fi

# ══════════════════════════════════════════════
# الاسترجاع قبل تشغيل n8n (إذا لا توجد DB)
# ══════════════════════════════════════════════
if [ ! -s "$N8N_DIR/database.sqlite" ]; then
  log "📦 لا توجد داتابيس - جاري الاسترجاع..."
  tg_msg "🔄 <b>جاري استرجاع البيانات...</b>"

  if bash /scripts/restore.sh 2>&1 | sed 's/^/[restore] /'; then
    if [ -s "$N8N_DIR/database.sqlite" ]; then
      log "✅ تم الاسترجاع بنجاح"
      tg_msg "✅ <b>تم استرجاع البيانات!</b>"
    else
      log "🆕 أول تشغيل - قاعدة بيانات جديدة"
      tg_msg "🆕 <b>أول تشغيل</b>"
    fi
  else
    log "⚠️ فشل الاسترجاع - سيبدأ بقاعدة بيانات جديدة"
  fi
else
  log "✅ الداتابيس موجودة: $(du -h "$N8N_DIR/database.sqlite" | cut -f1)"
fi

log ""
log "🚀 تشغيل n8n..."

# ══════════════════════════════════════════════
# تشغيل n8n في الخلفية
# ══════════════════════════════════════════════
n8n start &
N8N_PID=$!
log "✅ n8n PID: $N8N_PID"

# ── انتظر البورت ──
log "⏳ انتظار البورت $N8N_PORT..."
_w=0
while [ "$_w" -lt 60 ]; do
  curl -sf --max-time 2 "http://localhost:${N8N_PORT}/healthz" \
    >/dev/null 2>&1 && break
  sleep 2
  _w=$((_w + 2))
done

if curl -sf --max-time 2 "http://localhost:${N8N_PORT}/healthz" \
   >/dev/null 2>&1; then
  log "✅ n8n جاهز على البورت $N8N_PORT"
  tg_msg "🚀 <b>n8n شغّال!</b>
🌐 ${WEBHOOK_URL:-}
🤖 /start للتحكم"
else
  log "⚠️ n8n لم يستجب بعد 60s"
fi

# ══════════════════════════════════════════════
# البوت التفاعلي
# ══════════════════════════════════════════════
(
  sleep 5
  log "[bot] 🤖 تشغيل البوت..."
  while true; do
    bash /scripts/bot.sh 2>&1 | sed 's/^/[bot] /' || true
    log "[bot] ⚠️ توقف - إعادة بعد 10s"
    sleep 10
  done
) &

# ══════════════════════════════════════════════
# مراقب الباك أب
# ══════════════════════════════════════════════
(
  sleep 30
  log "[backup] 🔥 باك أب أولي..."
  bash /scripts/backup.sh 2>&1 | sed 's/^/[backup] /' || true

  while true; do
    sleep "$MONITOR_INTERVAL"
    [ -s "$N8N_DIR/database.sqlite" ] && \
      bash /scripts/backup.sh 2>&1 | sed 's/^/[backup] /' || true
  done
) &

# ══════════════════════════════════════════════
# Keep-Alive
# ══════════════════════════════════════════════
(
  while true; do
    sleep 240
    curl -sS --max-time 10 -o /dev/null \
      "http://localhost:${N8N_PORT}/healthz" 2>/dev/null || true
  done
) &

# ══════════════════════════════════════════════
# مراقب n8n - أعد تشغيله إذا مات
# ══════════════════════════════════════════════
while true; do
  sleep 5
  if ! kill -0 $N8N_PID 2>/dev/null; then
    log "⚠️ n8n توقف - إعادة التشغيل..."
    sleep 3
    n8n start &
    N8N_PID=$!
    log "✅ n8n PID جديد: $N8N_PID"
  fi
done
