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

log "╔══════════════════════════════════════╗"
log "║  n8n Smart Backup v6.0               ║"
log "║  Node: $(node --version)                    ║"
log "╚══════════════════════════════════════╝"

# ══════════════════════════════════════════════
# الاسترجاع أولاً قبل n8n
# ══════════════════════════════════════════════
if [ ! -s "$N8N_DIR/database.sqlite" ]; then
  log "📦 لا توجد DB - استرجاع..."
  tg_msg "🔄 <b>جاري استرجاع البيانات...</b>"

  bash /scripts/restore.sh 2>&1 | sed 's/^/[restore] /' || true

  if [ -s "$N8N_DIR/database.sqlite" ]; then
    _sz=$(du -h "$N8N_DIR/database.sqlite" | cut -f1)
    log "✅ تم الاسترجاع: $_sz"
    tg_msg "✅ <b>تم الاسترجاع!</b> حجم DB: $_sz"
  else
    log "🆕 أول تشغيل"
    tg_msg "🆕 <b>أول تشغيل - DB جديدة</b>"
  fi
else
  _sz=$(du -h "$N8N_DIR/database.sqlite" | cut -f1)
  log "✅ DB موجودة: $_sz"
fi

# ══════════════════════════════════════════════
# تشخيص
# ══════════════════════════════════════════════
log "=== تشخيص ==="
if [ -s "$N8N_DIR/database.sqlite" ]; then
  _tc=$(sqlite3 "$N8N_DIR/database.sqlite" \
    "SELECT count(*) FROM sqlite_master WHERE type='table';" 2>/dev/null || echo 0)
  _users=$(sqlite3 "$N8N_DIR/database.sqlite" \
    "SELECT count(*) FROM \"user\";" 2>/dev/null || echo "?")
  _emails=$(sqlite3 "$N8N_DIR/database.sqlite" \
    "SELECT email FROM \"user\" LIMIT 5;" 2>/dev/null || echo "?")
  _creds=$(sqlite3 "$N8N_DIR/database.sqlite" \
    "SELECT count(*) FROM credentials_entity;" 2>/dev/null || echo "?")
  _wf=$(sqlite3 "$N8N_DIR/database.sqlite" \
    "SELECT count(*) FROM workflow_entity;" 2>/dev/null || echo "?")
  _setup=$(sqlite3 "$N8N_DIR/database.sqlite" \
    "SELECT value FROM settings WHERE key='userManagement.isInstanceOwnerSetUp';" 2>/dev/null || echo "?")

  log "📋 جداول: $_tc"
  log "👤 مستخدمين: $_users | emails: $_emails"
  log "🔑 credentials: $_creds | ⚙️ workflows: $_wf"
  log "🔧 ownerSetUp: $_setup"

  tg_msg "🔍 <b>تشخيص DB:</b>
📋 جداول: <code>$_tc</code>
👤 مستخدمين: <code>$_users</code>
📧 <code>$_emails</code>
🔑 credentials: <code>$_creds</code>
⚙️ workflows: <code>$_wf</code>
🔧 ownerSetUp: <code>$_setup</code>
🔐 encKey: <code>${N8N_ENCRYPTION_KEY:+SET}${N8N_ENCRYPTION_KEY:-NOT SET}</code>"
fi
log "=== نهاية التشخيص ==="

# ══════════════════════════════════════════════
# تشغيل n8n
# ══════════════════════════════════════════════
log "🚀 تشغيل n8n..."
n8n start &
N8N_PID=$!
log "✅ n8n PID: $N8N_PID"

# ══════════════════════════════════════════════
# خلفية
# ══════════════════════════════════════════════
(
  _w=0
  while [ "$_w" -lt 120 ]; do
    curl -sf --max-time 2 \
      "http://localhost:${N8N_PORT}/healthz" \
      >/dev/null 2>&1 && break
    sleep 3
    _w=$((_w + 3))
  done
  log "[bg] ✅ n8n جاهز (${_w}s)"

  tg_msg "🚀 <b>n8n شغّال!</b>
🌐 ${WEBHOOK_URL:-}
🤖 /start للتحكم"

  log "[bg] 🤖 البوت..."
  while true; do
    bash /scripts/bot.sh 2>&1 | sed 's/^/[bot] /' || true
    log "[bg] ⚠️ البوت توقف - إعادة 10s"
    sleep 10
  done
) &

# ══════════════════════════════════════════════
# مراقب الباك أب
# ══════════════════════════════════════════════
(
  sleep 120
  log "[backup] 🔥 أولي..."
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
      "http://localhost:${N8N_PORT}/healthz" 2>/dev/null || true
  done
) &

# ══════════════════════════════════════════════
# مراقب n8n
# ══════════════════════════════════════════════
log "👀 مراقبة n8n..."
while true; do
  sleep 5
  if ! kill -0 $N8N_PID 2>/dev/null; then
    log "⚠️ n8n توقف - إعادة 5s..."
    sleep 5
    n8n start &
    N8N_PID=$!
    log "✅ n8n PID: $N8N_PID"
  fi
done
