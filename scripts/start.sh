#!/bin/sh
set -eu
umask 077

export WORK="${WORK:-/backup-data}"
export TMP="${WORK}/_tmp"
mkdir -p "$TMP" "$WORK/history"
rm -rf "$TMP"/* 2>/dev/null || true

N8N_DIR="${N8N_DIR:-/home/node/.n8n}"
MONITOR_INTERVAL="${MONITOR_INTERVAL:-45}"

mkdir -p "$N8N_DIR" "$WORK/history"
export HOME="/home/node"

: "${TG_BOT_TOKEN:?}"
: "${TG_CHAT_ID:?}"
: "${TG_ADMIN_ID:?}"

TG="https://api.telegram.org/bot${TG_BOT_TOKEN}"

tg_msg() {
  curl -sS -X POST "${TG}/sendMessage" \
    -d "chat_id=${TG_ADMIN_ID}" \
    -d "parse_mode=HTML" \
    -d "text=$1" >/dev/null 2>&1 || true
}

echo "n8n + Telegram Smart Backup v4.1 - Render Free Fixed"
echo "تم تفعيل وضع TMP الآمن"

# استرجاع تلقائي عند أول تشغيل
if [ ! -s "$N8N_DIR/database.sqlite" ]; then
  tg_msg "جاري استرجاع آخر باك أب..."
  if sh /scripts/restore.sh; then
    tg_msg "تم استرجاع البيانات بنجاح!"
  else
    tg_msg "أول تشغيل - لا توجد نسخة سابقة"
  fi
fi

# تشغيل البوت التفاعلي
(sh /scripts/bot.sh >/dev/null 2>&1) &

# Keep-Alive
(while true; do curl -sS -o /dev/null "http://localhost:5678/healthz" || true; sleep 300; done) &

# أول باك أب بعد 60 ثانية ثم كل 45 ثانية فحص
(sleep 60; sh /scripts/backup.sh; while true; do sleep "$MONITOR_INTERVAL"; sh /scripts/backup.sh; done) &

tg_msg "n8n شغال الآن!  
أرسل /start في البوت للتحكم"

exec n8n start
