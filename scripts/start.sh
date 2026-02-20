#!/bin/sh
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

tg_msg() {
  _txt="$1"
  curl -sS --max-time 15 -X POST "${TG}/sendMessage" \
    -d "chat_id=${TG_ADMIN_ID}" \
    -d "parse_mode=HTML" \
    --data-urlencode "text=${_txt}" \
    >/dev/null 2>&1 || true
}

log() { echo "[$(date '+%H:%M:%S')] $*"; }

log ""
log "╔══════════════════════════════════════════════╗"
log "║  n8n + Telegram Smart Backup v5.0            ║"
log "╚══════════════════════════════════════════════╝"
log ""

# ── فحص الأدوات ──
ALL_OK=true
for cmd in curl jq sqlite3 tar gzip split stat du awk cut tr find; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log "❌ missing: $cmd"
    ALL_OK=false
  fi
done

if [ "$ALL_OK" = "false" ]; then
  log "❌ أدوات ناقصة - يرجى مراجعة الـ Dockerfile"
  exit 1
fi
log "✅ كل الأدوات موجودة"

# ── فحص البوت ──
_bot_resp=$(curl -sS --max-time 10 "${TG}/getMe" 2>/dev/null || true)
BOT_OK=$(echo "$_bot_resp" | jq -r '.ok // "false"' 2>/dev/null || echo "false")
BOT_NAME=$(echo "$_bot_resp" | jq -r '.result.username // "?"' 2>/dev/null || echo "?")

if [ "$BOT_OK" = "true" ]; then
  log "✅ البوت: @${BOT_NAME}"
else
  log "❌ فشل الاتصال بالبوت - تأكد من TG_BOT_TOKEN"
  exit 1
fi

# ── الاسترجاع عند أول تشغيل ──
if [ ! -s "$N8N_DIR/database.sqlite" ]; then
  log ""
  log "📦 لا توجد داتابيس - جاري الاسترجاع..."
  tg_msg "🔄 <b>جاري استرجاع البيانات...</b>"

  if sh /scripts/restore.sh 2>&1; then
    if [ -s "$N8N_DIR/database.sqlite" ]; then
      log "✅ تم الاسترجاع!"
      tg_msg "✅ <b>تم استرجاع البيانات بنجاح!</b>"
    else
      log "🆕 أول تشغيل - لا توجد نسخة سابقة"
      tg_msg "🆕 <b>أول تشغيل - سيتم إنشاء قاعدة بيانات جديدة</b>"
    fi
  else
    log "🆕 أول تشغيل"
    tg_msg "🆕 <b>أول تشغيل</b>"
  fi
else
  log "✅ الداتابيس موجودة - $(du -h "$N8N_DIR/database.sqlite" | cut -f1)"
fi
log ""

# ── البوت التفاعلي في الخلفية ──
(
  sleep 15
  log "[bot] 🤖 تشغيل البوت التفاعلي..."
  while true; do
    sh /scripts/bot.sh 2>&1 | sed 's/^/[bot] /' || true
    log "[bot] ⚠️ البوت توقف - إعادة التشغيل بعد 10s..."
    sleep 10
  done
) &

# ── Keep-Alive لمنع Render من إيقاف الخدمة ──
(
  sleep 90
  log "[keepalive] 🔄 Keep-alive شغّال"
  while true; do
    curl -sS --max-time 10 -o /dev/null \
      "http://localhost:${N8N_PORT}/healthz" 2>/dev/null || true
    sleep 240
  done
) &

# ── مراقب الباك أب ──
(
  # انتظر n8n يشتغل
  sleep 60
  log "[backup] 🔥 باك أب أولي..."
  sh /scripts/backup.sh 2>&1 | sed 's/^/[backup] /' || true

  while true; do
    sleep "$MONITOR_INTERVAL"
    if [ -s "$N8N_DIR/database.sqlite" ]; then
      sh /scripts/backup.sh 2>&1 | sed 's/^/[backup] /' || true
    fi
  done
) &

tg_msg "🚀 <b>n8n شغّال الآن!</b>
🌐 ${WEBHOOK_URL:-غير محدد}
🤖 أرسل /start للتحكم"

log "🚀 تشغيل n8n..."
exec n8n start
