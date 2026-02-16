#!/bin/sh
set -eu
umask 077

D="${N8N_DIR:-/home/node/.n8n}"
W="${WORK:-/backup-data}"
MI="${MONITOR_INTERVAL:-30}"

mkdir -p "$D" "$W" "$W/h"
export HOME="/home/node"

: "${TG_BOT_TOKEN:?}" "${TG_CHAT_ID:?}" "${TG_ADMIN_ID:?}"
TG="https://api.telegram.org/bot${TG_BOT_TOKEN}"

# ── فحص سريع ──
for c in curl jq sqlite3 tar gzip split stat du awk find cut tr; do
  command -v "$c" >/dev/null 2>&1 || { echo "❌ $c"; exit 1; }
done

# ── استرجاع (قبل n8n) ──
if [ ! -s "$D/database.sqlite" ]; then
  echo "📦 استرجاع..."
  sh /scripts/restore.sh 2>&1 || true
  [ -s "$D/database.sqlite" ] && echo "✅ تم" || echo "🆕 أول تشغيل"
fi

# ── n8n بالخلفية فوراً ──
echo "🚀 n8n..."
n8n start &
P=$!

# انتظر البورت
T=0
while [ "$T" -lt 45 ]; do
  curl -so /dev/null "http://localhost:${N8N_PORT:-5678}/healthz" 2>/dev/null && break
  T=$((T+1)); sleep 2
done

# ── إشعار ──
curl -sS -X POST "${TG}/sendMessage" \
  -d "chat_id=${TG_ADMIN_ID}" -d "parse_mode=HTML" \
  -d "text=🚀 <b>n8n شغّال!</b> أرسل /start" >/dev/null 2>&1 || true

# ── البوت ──
( sleep 5; sh /scripts/bot.sh 2>&1 | sed 's/^/[bot] /' ) &

# ── Keep-Alive ──
( while true; do sleep 300
  curl -so /dev/null "http://localhost:${N8N_PORT:-5678}/healthz" 2>/dev/null || true
done ) &

# ── باك أب ──
( sleep 30
  [ -s "$D/database.sqlite" ] && {
    rm -f "$W/.bs"; sh /scripts/backup.sh 2>&1 | sed 's/^/[b] /' || true; }
  while true; do sleep "$MI"
    [ -s "$D/database.sqlite" ] && sh /scripts/backup.sh 2>&1 | sed 's/^/[b] /' || true
  done ) &

wait $P
