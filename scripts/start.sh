#!/bin/bash
set -eu
umask 077

N8N_DIR="${N8N_DIR:-/home/node/.n8n}"
WORK="${WORK:-/backup-data}"
MONITOR_INTERVAL="${MONITOR_INTERVAL:-60}"
N8N_PORT="${N8N_PORT:-5678}"

mkdir -p "$N8N_DIR" "$WORK" "$WORK/history"
export HOME="/home/node"

: "${TG_BOT_TOKEN:?}"
: "${TG_CHAT_ID:?}"
: "${TG_ADMIN_ID:?}"

TG="https://api.telegram.org/bot${TG_BOT_TOKEN}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

tg_msg() {
  curl -sS --max-time 15 -X POST "${TG}/sendMessage" \
    -d "chat_id=${TG_ADMIN_ID}" \
    -d "parse_mode=HTML" \
    --data-urlencode "text=$1" \
    >/dev/null 2>&1 || true
}

log "=== n8n Backup v5.4 | Node: $(node --version) ==="

# ══════════════════════════════════════════════
# الاسترجاع قبل n8n لكن بسرعة (timeout 30s)
# ══════════════════════════════════════════════
if [ ! -s "$N8N_DIR/database.sqlite" ]; then
  log "📦 لا توجد DB - استرجاع سريع (30s max)..."

  # timeout 30 ثانية للاسترجاع
  timeout 30 bash /scripts/restore.sh 2>&1 | \
    sed 's/^/[restore] /' || true

  if [ -s "$N8N_DIR/database.sqlite" ]; then
    log "✅ تم الاسترجاع قبل تشغيل n8n"
  else
    log "⏭️ لم يكتمل الاسترجاع - n8n سيبدأ فارغاً"
    log "   (الاسترجاع سيكتمل في الخلفية)"
  fi
fi

# ══════════════════════════════════════════════
# تشغيل n8n الآن
# ══════════════════════════════════════════════
log "🚀 تشغيل n8n..."
n8n start &
N8N_PID=$!
log "✅ n8n PID: $N8N_PID"

# ══════════════════════════════════════════════
# خلفية: استرجاع كامل إذا DB لا تزال فارغة
# ══════════════════════════════════════════════
(
  # انتظر n8n يفتح البورت أولاً
  _w=0
  while [ "$_w" -lt 60 ]; do
    curl -sf --max-time 2 \
      "http://localhost:${N8N_PORT}/healthz" \
      >/dev/null 2>&1 && break
    sleep 2
    _w=$((_w + 2))
  done
  log "[bg] ✅ n8n على البورت بعد ${_w}s"

  # إذا DB لا تزال فارغة - استرجاع كامل في الخلفية
  if [ ! -s "$N8N_DIR/database.sqlite" ]; then
    log "[bg] 📦 استرجاع كامل في الخلفية..."
    tg_msg "🔄 <b>جاري استرجاع البيانات في الخلفية...</b>"

    if bash /scripts/restore.sh 2>&1 | sed 's/^/[restore] /'; then
      if [ -s "$N8N_DIR/database.sqlite" ]; then
        log "[bg] ✅ تم الاسترجاع"
        tg_msg "✅ <b>تم الاسترجاع!</b>
⚠️ أعد تشغيل الخدمة من Render لتطبيق البيانات
أو اضغط /restart من البوت"
      fi
    fi
  else
    log "[bg] ✅ DB موجودة: $(du -h "$N8N_DIR/database.sqlite" | cut -f1)"
    tg_msg "🚀 <b>n8n جاهز!</b>
🌐 ${WEBHOOK_URL:-}
🤖 /start للتحكم"
  fi

  # ── البوت التفاعلي ──
  log "[bg] 🤖 البوت..."
  while true; do
    bash /scripts/bot.sh 2>&1 | sed 's/^/[bot] /' || true
    log "[bg] ⚠️ البوت توقف - إعادة بعد 10s"
    sleep 10
  done
) &

# ══════════════════════════════════════════════
# مراقب الباك أب
# ══════════════════════════════════════════════
(
  sleep 120
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
    sleep 200
    curl -sS --max-time 10 -o /dev/null \
      "http://localhost:${N8N_PORT}/healthz" \
      2>/dev/null || true
  done
) &

# ══════════════════════════════════════════════
# مراقب n8n - أعد تشغيله فقط إذا مات
# ══════════════════════════════════════════════
log "👀 مراقبة n8n..."
_restart_count=0
while true; do
  sleep 5
  if ! kill -0 $N8N_PID 2>/dev/null; then
    _restart_count=$((_restart_count + 1))
    log "⚠️ n8n توقف (#$_restart_count) - إعادة بعد 5s..."
    sleep 5
    n8n start &
    N8N_PID=$!
    log "✅ n8n PID: $N8N_PID"
  fi
done
