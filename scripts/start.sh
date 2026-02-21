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

log "=== n8n v5.4 | Node: $(node --version) ==="

# ══════════════════════════════════════════════
# الاسترجاع أولاً - قبل n8n
# لكن بحد أقصى 25 ثانية
# ══════════════════════════════════════════════
if [ ! -s "$N8N_DIR/database.sqlite" ]; then
  log "📦 استرجاع DB (max 25s)..."
  tg_msg "🔄 <b>استرجاع البيانات...</b>"

  if timeout 25 bash /scripts/restore.sh 2>&1 | \
      sed 's/^/[restore] /'; then
    if [ -s "$N8N_DIR/database.sqlite" ]; then
      _sz=$(du -h "$N8N_DIR/database.sqlite" | cut -f1)
      log "✅ DB مسترجعة: $_sz"
      tg_msg "✅ <b>تم استرجاع البيانات!</b>"
    else
      log "⚠️ لم تكتمل - ستكمل في الخلفية"
    fi
  else
    log "⚠️ timeout أو خطأ - ستكمل في الخلفية"
  fi
else
  _sz=$(du -h "$N8N_DIR/database.sqlite" | cut -f1)
  log "✅ DB موجودة: $_sz"
fi

# ══════════════════════════════════════════════
# تشغيل n8n
# ══════════════════════════════════════════════
log "🚀 تشغيل n8n..."
n8n start &
N8N_PID=$!
log "✅ n8n PID: $N8N_PID"

# ══════════════════════════════════════════════
# خلفية: استكمال الاسترجاع إذا لم تكتمل
# ══════════════════════════════════════════════
(
  # انتظر n8n يفتح البورت
  _w=0
  while [ "$_w" -lt 90 ]; do
    curl -sf --max-time 2 \
      "http://localhost:${N8N_PORT}/healthz" \
      >/dev/null 2>&1 && break
    sleep 3
    _w=$((_w + 3))
  done
  log "[bg] ✅ n8n على البورت (${_w}s)"

  # استكمال الاسترجاع إذا لم تكتمل
  if [ ! -s "$N8N_DIR/database.sqlite" ]; then
    log "[bg] 📦 استرجاع كامل في الخلفية..."
    if bash /scripts/restore.sh 2>&1 | sed 's/^/[restore] /'; then
      if [ -s "$N8N_DIR/database.sqlite" ]; then
        _sz=$(du -h "$N8N_DIR/database.sqlite" | cut -f1)
        log "[bg] ✅ DB مسترجعة: $_sz"
        tg_msg "✅ <b>تم الاسترجاع!</b>
⚠️ أعد تشغيل Render لتطبيق البيانات
أو استخدم /backup ثم /start"
      fi
    fi
  fi

  tg_msg "🚀 <b>n8n جاهز!</b>
🌐 ${WEBHOOK_URL:-}
🤖 /start للتحكم"

  # ── البوت ──
  log "[bg] 🤖 البوت..."
  while true; do
    bash /scripts/bot.sh 2>&1 | sed 's/^/[bot] /' || true
    log "[bg] ⚠️ البوت - إعادة 10s"
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
# مراقب n8n
# ══════════════════════════════════════════════
log "👀 مراقبة n8n..."
while true; do
  sleep 5
  if ! kill -0 $N8N_PID 2>/dev/null; then
    log "⚠️ n8n توقف - إعادة..."
    sleep 3
    n8n start &
    N8N_PID=$!
    log "✅ n8n PID: $N8N_PID"
  fi
done
