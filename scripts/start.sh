#!/bin/sh
set -eu
umask 077

N8N_DIR="${N8N_DIR:-/home/node/.n8n}"
WORK="${WORK:-/backup-data}"
MONITOR="${MONITOR_INTERVAL:-30}"

mkdir -p "$N8N_DIR" "$WORK" "$WORK/history"
export HOME="/home/node"

: "${TG_BOT_TOKEN:?}" "${TG_CHAT_ID:?}" "${TG_ADMIN_ID:?}"
TG="https://api.telegram.org/bot${TG_BOT_TOKEN}"

# ── فحص الأدوات ──
for cmd in curl jq sqlite3 tar gzip split stat du awk find cut tr; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "❌ مو موجود: $cmd"; exit 1; }
done
echo "✅ كل الأدوات موجودة"

# ── استرجاع (قبل n8n) ──
if [ ! -s "$N8N_DIR/database.sqlite" ]; then
  echo "📦 محاولة استرجاع..."
  sh /scripts/restore.sh 2>&1 || true
  if [ -s "$N8N_DIR/database.sqlite" ]; then
    echo "✅ تم الاسترجاع"
  else
    echo "🆕 أول تشغيل - بدون نسخة سابقة"
  fi
fi

# ── تشغيل n8n ──
echo "🚀 تشغيل n8n..."
n8n start &
N8N_PID=$!

# انتظار البورت
_wait=0
while [ "$_wait" -lt 45 ]; do
  if curl -so /dev/null "http://localhost:${N8N_PORT:-5678}/healthz" 2>/dev/null; then
    echo "✅ n8n جاهز!"
    break
  fi
  _wait=$((_wait + 1))
  sleep 2
done

# ── إشعار ──
curl -sS -X POST "${TG}/sendMessage" \
  -d "chat_id=${TG_ADMIN_ID}" \
  -d "parse_mode=HTML" \
  -d "text=🚀 <b>n8n شغّال!</b>
أرسل /start للتحكم" >/dev/null 2>&1 || true

# ── البوت ──
( sleep 5; sh /scripts/bot.sh 2>&1 | sed 's/^/[bot] /' ) &

# ── Keep-Alive ──
( while true; do
    sleep 300
    curl -so /dev/null "http://localhost:${N8N_PORT:-5678}/healthz" 2>/dev/null || true
  done ) &

# ── باك أب دوري ──
( sleep 30
  # أول باك أب
  if [ -s "$N8N_DIR/database.sqlite" ]; then
    rm -f "$WORK/.backup_state"
    sh /scripts/backup.sh 2>&1 | sed 's/^/[backup] /' || true
  fi
  # دوري
  while true; do
    sleep "$MONITOR"
    if [ -s "$N8N_DIR/database.sqlite" ]; then
      sh /scripts/backup.sh 2>&1 | sed 's/^/[backup] /' || true
    fi
  done ) &

wait $N8N_PID
