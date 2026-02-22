#!/bin/sh
set -eu
umask 077

N8N_DIR="${N8N_DIR:-/home/node/.n8n}"
WORK="${WORK:-/backup-data}"
MONITOR_INTERVAL="${MONITOR_INTERVAL:-30}"

mkdir -p "$N8N_DIR" "$WORK"
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

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  n8n + Telegram Backup (DB-only) v5.0        ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# ── فحص الأدوات ──
ALL_OK=true
for cmd in curl jq sqlite3 gzip stat du awk cut tr; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "❌ $cmd"; ALL_OK=false; }
done
[ "$ALL_OK" = "true" ] || exit 1
echo "✅ كل الأدوات موجودة"

# ── فحص البوت ──
BOT_OK=$(curl -sS "${TG}/getMe" | jq -r '.ok // "false"')
BOT_NAME=$(curl -sS "${TG}/getMe" | jq -r '.result.username // "?"')
if [ "$BOT_OK" = "true" ]; then
  echo "✅ البوت: @${BOT_NAME}"
else
  echo "❌ فشل الاتصال بالبوت"
  exit 1
fi

# ── الاسترجاع ──
if [ ! -s "$N8N_DIR/database.sqlite" ]; then
  echo ""
  echo "📦 لا توجد داتابيس - جاري الاسترجاع..."
  tg_msg "🔄 <b>جاري استرجاع البيانات...</b>"

  if sh /scripts/restore.sh 2>&1; then
    if [ -s "$N8N_DIR/database.sqlite" ]; then
      _tc=$(sqlite3 "$N8N_DIR/database.sqlite" \
        "SELECT count(*) FROM sqlite_master WHERE type='table';" 2>/dev/null || echo 0)
      echo "✅ تم الاسترجاع! ($_tc جدول)"
      tg_msg "✅ <b>تم استرجاع البيانات!</b> ($_tc جدول)"
    else
      echo "🆕 أول تشغيل"
      tg_msg "🆕 <b>أول تشغيل - لا توجد نسخة سابقة</b>"
    fi
  else
    echo "🆕 أول تشغيل - لا نسخة سابقة"
  fi
else
  _tc=$(sqlite3 "$N8N_DIR/database.sqlite" \
    "SELECT count(*) FROM sqlite_master WHERE type='table';" 2>/dev/null || echo 0)
  echo "✅ الداتابيس موجودة ($_tc جدول)"
fi
echo ""

# ── البوت التفاعلي ──
(
  sleep 10
  echo "[bot] 🤖 البوت التفاعلي شغّال"
  sh /scripts/bot.sh 2>&1 | sed 's/^/[bot] /' &
) &

# ── Keep-Alive ──
(
  sleep 60
  while true; do
    curl -sS -o /dev/null \
      "http://localhost:${N8N_PORT:-5678}/healthz" 2>/dev/null || true
    sleep 300
  done
) &

# ── مراقب الباك أب ──
(
  sleep 45
  if [ -s "$N8N_DIR/database.sqlite" ]; then
    echo "[backup] 🔥 باك أب أولي"
    rm -f "$WORK/.backup_state"
    sh /scripts/backup.sh 2>&1 | sed 's/^/[backup] /' || true
  fi

  while true; do
    sleep "$MONITOR_INTERVAL"
    [ -s "$N8N_DIR/database.sqlite" ] && \
      sh /scripts/backup.sh 2>&1 | sed 's/^/[backup] /' || true
  done
) &

tg_msg "🚀 <b>n8n شغّال الآن!</b>
🤖 أرسل /start للتحكم"

echo "🚀 تشغيل n8n..."
exec n8n start
