#!/bin/sh
set -eu
umask 077

N8N_DIR="${N8N_DIR:-/home/node/.n8n}"
WORK="${WORK:-/backup-data}"
MONITOR_INTERVAL="${MONITOR_INTERVAL:-60}"

mkdir -p "$N8N_DIR" "$WORK" "$WORK/history"
export HOME="/home/node"

: "${TG_BOT_TOKEN:?Set TG_BOT_TOKEN}"
: "${TG_CHAT_ID:?Set TG_CHAT_ID}"
: "${TG_ADMIN_ID:?Set TG_ADMIN_ID}"

TG="https://api.telegram.org/bot${TG_BOT_TOKEN}"

tg_msg() {
  curl -sS -X POST "${TG}/sendMessage" \
    -d "chat_id=${TG_ADMIN_ID}" \
    -d "parse_mode=HTML" \
    -d "text=$1" >/dev/null 2>&1 || true
}

echo "\n╔══════════════════════════════════════════════╗"
echo "║  n8n + Telegram Smart Backup v5.0 (Render)   ║"
echo "╚══════════════════════════════════════════════╝\n"

BOT_OK=$(curl -sS "${TG}/getMe" | jq -r '.ok // "false"')
BOT_NAME=$(curl -sS "${TG}/getMe" | jq -r '.result.username // "?"')
if [ "$BOT_OK" = "true" ]; then
  echo "✅ البوت: @${BOT_NAME}"
else
  echo "❌ فشل الاتصال بالبوت"; exit 1
fi

if [ ! -s "$N8N_DIR/database.sqlite" ]; then
  echo "\n📦 لا توجد داتابيس - جاري الاسترجاع..."
  tg_msg "🔄 <b>جاري استرجاع البيانات...</b>"

  if sh /scripts/restore.sh 2>&1; then
    if [ -s "$N8N_DIR/database.sqlite" ]; then
      echo "✅ تم الاسترجاع!"
      tg_msg "✅ <b>تم استرجاع البيانات بنجاح!</b>"
    else
      echo "🆕 أول تشغيل"
    fi
  else
    echo "🆕 أول تشغيل"
  fi
else
  echo "✅ الداتابيس موجودة"
fi

(
  sleep 10
  echo "[bot] 🤖 البوت التفاعلي شغّال"
  sh /scripts/bot.sh 2>&1 | sed 's/^/[bot] /'
) &

(
  sleep 45
  if [ -s "$N8N_DIR/database.sqlite" ]; then
    echo "[backup] 🔥 باك أب فوري عند التشغيل"
    rm -f "$WORK/.backup_state"
    sh /scripts/backup.sh 2>&1 | sed 's/^/[backup] /' || true
  fi

  while true; do
    sleep "$MONITOR_INTERVAL"
    [ -s "$N8N_DIR/database.sqlite" ] && sh /scripts/backup.sh 2>&1 | sed 's/^/[backup] /' || true
  done
) &

tg_msg "🚀 <b>n8n شغّال الآن!</b>\n🤖 أرسل /start للتحكم"

echo "🚀 تشغيل n8n..."
# We start n8n in the background so we can listen for Render's Shutdown signal
n8n start &
N8N_PID=$!

# THE TRICK: When Render Free spins down, it sends SIGTERM. We catch it, backup, and die safely.
shutdown_handler() {
  echo "🛑 Render Shutdown Signal Received! Running emergency backup..."
  sh /scripts/backup.sh || true
  echo "🛑 Stopping n8n..."
  kill -TERM $N8N_PID 2>/dev/null || true
  wait $N8N_PID 2>/dev/null || true
  exit 0
}

trap 'shutdown_handler' SIGTERM SIGINT

wait $N8N_PID
