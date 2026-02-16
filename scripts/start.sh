#!/bin/sh
set -eu
umask 077

MONITOR_INTERVAL="${MONITOR_INTERVAL:-45}"
N8N_DIR="${N8N_DIR:-/home/node/.n8n}"
WORK="${WORK:-/backup-data}"
INIT_FLAG="$WORK/.initialized"

mkdir -p "$N8N_DIR" "$WORK"
export HOME="/home/node"

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  n8n + Telegram Backup System v3.0           ║"
echo "║  $(date -u)                   ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# ── فحص الأدوات ──
echo "🔎 فحص الأدوات:"
ALL_OK=true
for cmd in curl jq sqlite3 tar gzip split sha256sum \
           stat du sort awk xargs find cut tr cat grep sed; do
  if command -v "$cmd" >/dev/null 2>&1; then
    printf "  ✅ %s\n" "$cmd"
  else
    printf "  ❌ %s\n" "$cmd"
    ALL_OK=false
  fi
done

[ "$ALL_OK" = "true" ] || { echo "❌ أدوات مفقودة"; exit 1; }
echo ""

# ── فحص Telegram ──
echo "🔎 فحص اتصال Telegram:"
: "${TG_BOT_TOKEN:?Set TG_BOT_TOKEN}"
: "${TG_CHAT_ID:?Set TG_CHAT_ID}"

TG_TEST=$(curl -sS "https://api.telegram.org/bot${TG_BOT_TOKEN}/getMe" \
  | jq -r '.ok // "false"')

if [ "$TG_TEST" = "true" ]; then
  BOT_NAME=$(curl -sS "https://api.telegram.org/bot${TG_BOT_TOKEN}/getMe" \
    | jq -r '.result.username // "unknown"')
  echo "  ✅ البوت متصل: @${BOT_NAME}"
else
  echo "  ❌ فشل الاتصال بالبوت"
  exit 1
fi
echo ""

# ── الاسترجاع ──
if [ ! -s "$N8N_DIR/database.sqlite" ]; then
  echo "📦 لا توجد قاعدة بيانات محلية"
  echo "🔄 البحث عن آخر باك أب في Telegram..."
  echo ""

  restore_ok=false
  if sh /scripts/restore.sh 2>&1; then
    [ -s "$N8N_DIR/database.sqlite" ] && restore_ok=true
  fi

  if [ "$restore_ok" = "true" ]; then
    echo "✅ تم الاسترجاع بنجاح!"
  else
    echo "📭 لا توجد نسخة سابقة - أول تشغيل"
  fi

  echo "init:$(date -u)" > "$INIT_FLAG"
else
  echo "✅ قاعدة البيانات موجودة"
  [ -f "$INIT_FLAG" ] || echo "init:$(date -u)" > "$INIT_FLAG"
fi
echo ""

# ── Keep-Alive ──
(
  sleep 60
  echo "[keepalive] 🟢 شغّال"
  while true; do
    curl -sS -o /dev/null \
      "http://localhost:${N8N_PORT:-5678}/healthz" 2>/dev/null || true
    sleep 300
  done
) &

# ── مراقب الباك أب ──
(
  echo "[backup] ⏳ انتظار 60 ثانية..."
  sleep 60

  # باك أب فوري
  if [ -s "$N8N_DIR/database.sqlite" ]; then
    echo "[backup] 🔥 باك أب فوري"
    rm -f "$WORK/.backup_state" 2>/dev/null || true
    sh /scripts/backup.sh 2>&1 | sed 's/^/[backup] /' || true
  fi

  echo "[backup] 🔄 مراقبة كل ${MONITOR_INTERVAL}s"
  while true; do
    sleep "$MONITOR_INTERVAL"
    [ -s "$N8N_DIR/database.sqlite" ] && \
      sh /scripts/backup.sh 2>&1 | sed 's/^/[backup] /' || true
  done
) &

echo "🚀 تشغيل n8n..."
echo ""
exec n8n start
