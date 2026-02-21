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

log "=== n8n Backup v5.3 ==="
log "Node: $(node --version)"

# ══════════════════════════════════════════════
# تشغيل n8n فوراً - أول شيء بدون أي انتظار
# ══════════════════════════════════════════════
log "🚀 تشغيل n8n على البورت $N8N_PORT..."
n8n start &
N8N_PID=$!
log "✅ n8n PID: $N8N_PID"

# ══════════════════════════════════════════════
# كل الباقي في الخلفية بعد ما n8n يشتغل
# ══════════════════════════════════════════════
(
  # انتظر n8n يفتح البورت
  log "[bg] ⏳ انتظار n8n..."
  _w=0
  while [ "$_w" -lt 120 ]; do
    if curl -sf --max-time 2 \
      "http://localhost:${N8N_PORT}/healthz" \
      >/dev/null 2>&1; then
      log "[bg] ✅ n8n جاهز بعد ${_w}s"
      break
    fi
    sleep 3
    _w=$((_w + 3))
  done

  # فحص البوت
  _bot=$(curl -sS --max-time 10 "${TG}/getMe" 2>/dev/null || true)
  _bn=$(echo "$_bot" | jq -r '.result.username // "?"' 2>/dev/null || echo "?")
  log "[bg] 🤖 البوت: @$_bn"

  # ── الاسترجاع إذا لا توجد DB ──
  if [ ! -s "$N8N_DIR/database.sqlite" ]; then
    log "[bg] 📦 استرجاع البيانات..."
    tg_msg "🔄 <b>جاري استرجاع البيانات...</b>"

    if bash /scripts/restore.sh 2>&1 | sed 's/^/[restore] /'; then
      if [ -s "$N8N_DIR/database.sqlite" ]; then
        log "[bg] ✅ تم الاسترجاع - إعادة تشغيل n8n"
        tg_msg "✅ <b>تم الاسترجاع!</b> جاري إعادة تشغيل n8n..."
        kill $N8N_PID 2>/dev/null || true
        sleep 5
        n8n start &
        N8N_PID=$!
        log "[bg] ✅ n8n جديد PID: $N8N_PID"
      else
        log "[bg] 🆕 أول تشغيل"
        tg_msg "🆕 <b>أول تشغيل - قاعدة بيانات جديدة</b>"
      fi
    fi
  else
    log "[bg] ✅ DB موجودة: $(du -h "$N8N_DIR/database.sqlite" | cut -f1)"
  fi

  tg_msg "🚀 <b>n8n جاهز!</b>
🌐 ${WEBHOOK_URL:-}
🤖 /start للتحكم"

  # ── البوت التفاعلي ──
  log "[bg] 🤖 تشغيل البوت..."
  while true; do
    bash /scripts/bot.sh 2>&1 | sed 's/^/[bot] /' || true
    log "[bg] ⚠️ البوت توقف - إعادة بعد 10s"
    sleep 10
  done
) &

# ══════════════════════════════════════════════
# مراقب الباك أب في الخلفية
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
    sleep 240
    curl -sS --max-time 10 -o /dev/null \
      "http://localhost:${N8N_PORT}/healthz" \
      2>/dev/null || true
  done
) &

# ══════════════════════════════════════════════
# الحلقة الرئيسية - مراقبة n8n وإعادة تشغيله
# ══════════════════════════════════════════════
log "👀 مراقبة n8n..."
while true; do
  sleep 5
  if ! kill -0 $N8N_PID 2>/dev/null; then
    log "⚠️ n8n توقف - إعادة التشغيل..."
    sleep 3
    n8n start &
    N8N_PID=$!
    log "✅ n8n PID: $N8N_PID"
  fi
done
