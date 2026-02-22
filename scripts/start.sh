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
echo "║  n8n + Telegram Backup v5.1 (DB-only)        ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# ── الاسترجاع السريع ──
if [ ! -s "$N8N_DIR/database.sqlite" ]; then
  echo "📦 جاري الاسترجاع..."
  sh /scripts/restore.sh 2>&1 || true

  if [ -s "$N8N_DIR/database.sqlite" ]; then
    _tc=$(sqlite3 "$N8N_DIR/database.sqlite" \
      "SELECT count(*) FROM sqlite_master WHERE type='table';" 2>/dev/null || echo 0)
    echo "✅ تم الاسترجاع! ($_tc جدول)"
  else
    echo "🆕 أول تشغيل"
  fi
else
  echo "✅ الداتابيس موجودة"
fi

# ── تنظيف binaryData القديمة عند كل تشغيل ──
if [ -d "$N8N_DIR/binaryData" ]; then
  _bsize=$(du -sm "$N8N_DIR/binaryData" 2>/dev/null | cut -f1 || echo 0)
  echo "🧹 تنظيف binaryData ($_bsize MB)..."
  rm -rf "$N8N_DIR/binaryData"
  mkdir -p "$N8N_DIR/binaryData"
  echo "✅ تم التنظيف"
fi

echo ""

# ── كل شي ثاني بالخلفية ──
(
  _wait=0
  while [ "$_wait" -lt 120 ]; do
    if curl -sS -o /dev/null "http://localhost:${N8N_PORT:-5678}/healthz" 2>/dev/null; then
      break
    fi
    sleep 3
    _wait=$((_wait + 3))
  done

  tg_msg "🚀 <b>n8n شغّال!</b> أرسل /start للتحكم"

  # البوت
  sh /scripts/bot.sh 2>&1 | sed 's/^/[bot] /' &

  # أول باك أب
  sleep 15
  if [ -s "$N8N_DIR/database.sqlite" ]; then
    rm -f "$WORK/.backup_state"
    sh /scripts/backup.sh 2>&1 | sed 's/^/[backup] /' || true
  fi

  # مراقب الباك أب
  while true; do
    sleep "$MONITOR_INTERVAL"
    [ -s "$N8N_DIR/database.sqlite" ] && \
      sh /scripts/backup.sh 2>&1 | sed 's/^/[backup] /' || true
  done
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

# ── تنظيف binaryData دوري (كل 6 ساعات) ──
(
  while true; do
    sleep 21600
    if [ -d "$N8N_DIR/binaryData" ]; then
      _bs=$(du -sm "$N8N_DIR/binaryData" 2>/dev/null | cut -f1 || echo 0)
      if [ "$_bs" -gt 50 ]; then
        echo "[cleanup] 🧹 binaryData: ${_bs}MB → تنظيف"
        find "$N8N_DIR/binaryData" -type f -mmin +60 -delete 2>/dev/null || true
        find "$N8N_DIR/binaryData" -type d -empty -delete 2>/dev/null || true
      fi
    fi
  done
) &

echo "🚀 تشغيل n8n..."
exec n8n start
