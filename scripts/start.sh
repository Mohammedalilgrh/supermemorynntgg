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

log "=== n8n Backup v6.1 | Node: $(node --version) ==="

# ══════════════════════════════════════════════
# الاسترجاع
# ══════════════════════════════════════════════
if [ ! -s "$N8N_DIR/database.sqlite" ]; then
  log "📦 استرجاع DB..."
  tg_msg "🔄 <b>استرجاع...</b>"
  bash /scripts/restore.sh 2>&1 | sed 's/^/[restore] /' || true

  if [ -s "$N8N_DIR/database.sqlite" ]; then
    log "✅ تم الاسترجاع"
    tg_msg "✅ <b>تم الاسترجاع!</b>"
  else
    log "🆕 أول تشغيل"
    tg_msg "🆕 <b>أول تشغيل</b>"
  fi
else
  log "✅ DB: $(du -h "$N8N_DIR/database.sqlite" | cut -f1)"
fi

# ══════════════════════════════════════════════
# تشخيص
# ══════════════════════════════════════════════
if [ -s "$N8N_DIR/database.sqlite" ]; then
  _tc=$(sqlite3 "$N8N_DIR/database.sqlite" \
    "SELECT count(*) FROM sqlite_master WHERE type='table';" 2>/dev/null || echo 0)
  _users=$(sqlite3 "$N8N_DIR/database.sqlite" \
    "SELECT count(*) FROM \"user\";" 2>/dev/null || echo "?")
  _emails=$(sqlite3 "$N8N_DIR/database.sqlite" \
    "SELECT email FROM \"user\" LIMIT 5;" 2>/dev/null || echo "?")
  _setup=$(sqlite3 "$N8N_DIR/database.sqlite" \
    "SELECT value FROM settings WHERE key='userManagement.isInstanceOwnerSetUp';" 2>/dev/null || echo "?")
  _role=$(sqlite3 "$N8N_DIR/database.sqlite" \
    "SELECT role FROM \"user\" ORDER BY \"createdAt\" ASC LIMIT 1;" 2>/dev/null || echo "?")
  _wf=$(sqlite3 "$N8N_DIR/database.sqlite" \
    "SELECT count(*) FROM workflow_entity;" 2>/dev/null || echo "?")
  _cred=$(sqlite3 "$N8N_DIR/database.sqlite" \
    "SELECT count(*) FROM credentials_entity;" 2>/dev/null || echo "?")

  log "📋 tables:$_tc users:$_users emails:$_emails"
  log "🔧 setup:$_setup role:$_role wf:$_wf cred:$_cred"
  log "🔐 config: $(cat "$N8N_DIR/config" 2>/dev/null | head -c 40 || echo 'NONE')..."
  log "🔐 encKey env: ${N8N_ENCRYPTION_KEY:+SET}${N8N_ENCRYPTION_KEY:-NOT SET}"

  tg_msg "🔍 <b>DB تشخيص:</b>
📋 جداول: <code>$_tc</code>
👤 مستخدمين: <code>$_users</code>
📧 <code>$_emails</code>
🔧 ownerSetUp: <code>$_setup</code>
👑 أول role: <code>$_role</code>
⚙️ workflows: <code>$_wf</code>
🔑 credentials: <code>$_cred</code>
🔐 encKey: <code>${N8N_ENCRYPTION_KEY:+SET}${N8N_ENCRYPTION_KEY:-NOT}</code>
📄 config: <code>$([ -f "$N8N_DIR/config" ] && echo YES || echo NO)</code>"
fi

# ══════════════════════════════════════════════
# n8n
# ══════════════════════════════════════════════
log "🚀 n8n..."
n8n start &
N8N_PID=$!
log "✅ PID: $N8N_PID"

# ══════════════════════════════════════════════
# خلفية
# ══════════════════════════════════════════════
(
  _w=0
  while [ "$_w" -lt 120 ]; do
    curl -sf --max-time 2 "http://localhost:${N8N_PORT}/healthz" \
      >/dev/null 2>&1 && break
    sleep 3; _w=$((_w + 3))
  done
  log "[bg] ✅ n8n جاهز (${_w}s)"
  tg_msg "🚀 <b>n8n جاهز!</b>
🌐 ${WEBHOOK_URL:-}
🤖 /start"

  while true; do
    bash /scripts/bot.sh 2>&1 | sed 's/^/[bot] /' || true
    sleep 10
  done
) &

(
  sleep 120
  bash /scripts/backup.sh 2>&1 | sed 's/^/[backup] /' || true
  while true; do
    sleep "$MONITOR_INTERVAL"
    [ -s "$N8N_DIR/database.sqlite" ] && \
      bash /scripts/backup.sh 2>&1 | sed 's/^/[backup] /' || true
  done
) &

(
  while true; do
    sleep 200
    curl -sS --max-time 10 -o /dev/null \
      "http://localhost:${N8N_PORT}/healthz" 2>/dev/null || true
  done
) &

log "👀 مراقبة..."
while true; do
  sleep 5
  if ! kill -0 $N8N_PID 2>/dev/null; then
    log "⚠️ n8n توقف"
    sleep 5
    n8n start &
    N8N_PID=$!
    log "✅ PID: $N8N_PID"
  fi
done
