#!/bin/sh
set -eu
umask 077

N8N_DIR="${N8N_DIR:-/home/node/.n8n}"
WORK="${WORK:-/backup-data}"
MONITOR_INTERVAL="${MONITOR_INTERVAL:-60}"
N8N_PORT="${N8N_PORT:-5678}"
PORT="${PORT:-5678}"

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
log "║  n8n + Telegram Smart Backup v5.1            ║"
log "╚══════════════════════════════════════════════╝"
log ""

# ── فحص الأدوات ──
ALL_OK=true
for cmd in curl jq sqlite3 tar gzip split stat du awk cut tr find bash; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    log "❌ missing: $cmd"
    ALL_OK=false
  fi
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
  log "⚠️ تحذير: فشل الاتصال بالبوت - سيستمر التشغيل"
fi

log ""
log "🚀 تشغيل n8n فوراً (Render port check)..."

# ══════════════════════════════════════════════
# الخطوة الأساسية: n8n يشتغل فوراً في الخلفية
# بدون انتظار - Render يحتاج يشوف البورت
# ══════════════════════════════════════════════
n8n start &
N8N_PID=$!
log "✅ n8n PID: $N8N_PID"

# ── انتظر حتى يفتح البورت (أقصى 120 ثانية) ──
log "⏳ انتظار فتح البورت $N8N_PORT..."
_waited=0
_port_open=false
while [ "$_waited" -lt 120 ]; do
  if curl -sf --max-time 3 \
    "http://localhost:${N8N_PORT}/healthz" \
    >/dev/null 2>&1; then
    _port_open=true
    break
  fi
  sleep 2
  _waited=$((_waited + 2))
done

if [ "$_port_open" = "true" ]; then
  log "✅ البورت $N8N_PORT مفتوح بعد ${_waited}s"
else
  log "⚠️ البورت لم يفتح بعد ${_waited}s - نكمل على أي حال"
fi

# ══════════════════════════════════════════════
# الاسترجاع بعد ما n8n اشتغل
# ══════════════════════════════════════════════
(
  # انتظر إضافي للتأكد
  sleep 5

  if [ ! -s "$N8N_DIR/database.sqlite" ]; then
    log "[restore] 📦 لا توجد داتابيس - جاري الاسترجاع..."
    tg_msg "🔄 <b>جاري استرجاع البيانات...</b>"

    if sh /scripts/restore.sh 2>&1 | sed 's/^/[restore] /'; then
      if [ -s "$N8N_DIR/database.sqlite" ]; then
        log "[restore] ✅ تم الاسترجاع - يجب إعادة تشغيل n8n"
        tg_msg "✅ <b>تم استرجاع البيانات!</b>
⚠️ أعد تشغيل الخدمة من Render لتطبيق البيانات"
        # أوقف n8n وأعد تشغيله بالبيانات الجديدة
        kill $N8N_PID 2>/dev/null || true
        sleep 3
        log "[restore] 🔄 إعادة تشغيل n8n بالبيانات المسترجعة..."
        n8n start &
        N8N_PID=$!
        log "[restore] ✅ n8n أعيد تشغيله PID: $N8N_PID"
      else
        log "[restore] 🆕 أول تشغيل - لا توجد نسخة سابقة"
        tg_msg "🆕 <b>أول تشغيل - قاعدة بيانات جديدة</b>"
      fi
    else
      log "[restore] ⚠️ فشل الاسترجاع - n8n سيعمل بقاعدة بيانات فارغة"
    fi
  else
    log "[restore] ✅ الداتابيس موجودة: $(du -h "$N8N_DIR/database.sqlite" | cut -f1)"
  fi
) &

# ══════════════════════════════════════════════
# البوت التفاعلي
# ══════════════════════════════════════════════
(
  sleep 20
  log "[bot] 🤖 تشغيل البوت..."
  while true; do
    sh /scripts/bot.sh 2>&1 | sed 's/^/[bot] /' || true
    log "[bot] ⚠️ البوت توقف - إعادة بعد 10s"
    sleep 10
  done
) &

# ══════════════════════════════════════════════
# مراقب الباك أب
# ══════════════════════════════════════════════
(
  # انتظر حتى يكتمل الاسترجاع
  sleep 90

  log "[backup] 🔥 باك أب أولي..."
  sh /scripts/backup.sh 2>&1 | sed 's/^/[backup] /' || true

  while true; do
    sleep "$MONITOR_INTERVAL"
    if [ -s "$N8N_DIR/database.sqlite" ]; then
      sh /scripts/backup.sh 2>&1 | sed 's/^/[backup] /' || true
    fi
  done
) &

# ══════════════════════════════════════════════
# Keep-Alive (يمنع Render من إيقاف الخدمة)
# ══════════════════════════════════════════════
(
  sleep 30
  while true; do
    curl -sS --max-time 10 -o /dev/null \
      "http://localhost:${N8N_PORT}/healthz" 2>/dev/null || true
    sleep 240
  done
) &

tg_msg "🚀 <b>n8n شغّال!</b>
🌐 ${WEBHOOK_URL:-}
🤖 /start للتحكم"

log "✅ كل الخدمات شغّالة"
log "👀 مراقبة n8n (PID: $N8N_PID)..."

# ══════════════════════════════════════════════
# انتظر n8n - إذا مات أعد تشغيله
# ══════════════════════════════════════════════
while true; do
  if ! kill -0 $N8N_PID 2>/dev/null; then
    log "⚠️ n8n توقف - إعادة التشغيل..."
    n8n start &
    N8N_PID=$!
    log "✅ n8n أعيد تشغيله PID: $N8N_PID"
  fi
  sleep 10
done
