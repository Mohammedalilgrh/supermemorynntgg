#!/bin/sh
set -eu
umask 077

N8N_DIR="${N8N_DIR:-/home/node/.n8n}"
WORK="${WORK:-/backup-data}"
MONITOR_INTERVAL="${MONITOR_INTERVAL:-300}"

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
    --data-urlencode "text=$1" >/dev/null 2>&1 || true
}

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  n8n + Telegram Backup v8.0                   ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# ── الاسترجاع ──
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

# ── تنظيف binaryData عند التشغيل ──
rm -rf "$N8N_DIR/binaryData" 2>/dev/null || true
mkdir -p "$N8N_DIR/binaryData"
echo "🧹 binaryData نظيف"

# ── تنظيف DB عند التشغيل ──
if [ -s "$N8N_DIR/database.sqlite" ]; then
  echo "🗄️ تنظيف سجلات قديمة..."
  _before=$(du -h "$N8N_DIR/database.sqlite" | cut -f1)
  sqlite3 "$N8N_DIR/database.sqlite" "
    DELETE FROM execution_entity;
    DELETE FROM execution_data WHERE executionId NOT IN (SELECT id FROM execution_entity);
    DROP TABLE IF EXISTS execution_metadata;
    DROP TABLE IF EXISTS workflow_statistics;
    VACUUM;
  " 2>/dev/null || true
  _after=$(du -h "$N8N_DIR/database.sqlite" | cut -f1)
  echo "✅ DB: $_before → $_after"
fi

echo ""

# ── بوت + باك أب ──
(
  _wait=0
  while [ "$_wait" -lt 120 ]; do
    curl -sS -o /dev/null "http://localhost:${N8N_PORT:-5678}/healthz" 2>/dev/null && break
    sleep 3; _wait=$((_wait + 3))
  done

  tg_msg "🚀 n8n شغّال! أرسل /start"

  # FIX #9: loop يعيد تشغيل bot.sh تلقائياً عند crash
  # FIX #10: نكتب لـ /dev/null بدل log file يكبر بلا حد
  (
    while true; do
      sh /scripts/bot.sh > /dev/null 2>&1 || true
      echo "[bot] إعادة تشغيل بعد 5 ثواني..."
      sleep 5
    done
  ) &

  sleep 30
  if [ -s "$N8N_DIR/database.sqlite" ]; then
    rm -f "$WORK/.backup_state"
    sh /scripts/backup.sh > /dev/null 2>&1 || true
  fi

  while true; do
    sleep "$MONITOR_INTERVAL"
    [ -s "$N8N_DIR/database.sqlite" ] && \
      sh /scripts/backup.sh > /dev/null 2>&1 || true
  done
) &

# ── Keep-Alive ──
(
  sleep 60
  while true; do
    curl -sS -o /dev/null "http://localhost:${N8N_PORT:-5678}/healthz" 2>/dev/null || true
    [ -n "${N8N_HOST:-}" ] && \
      curl -sS -o /dev/null "https://${N8N_HOST}/healthz" 2>/dev/null || true
    sleep 240
  done
) &

# ── تنظيف binaryData كل 10 دقائق ──
(
  sleep 600
  while true; do
    [ -d "$N8N_DIR/binaryData" ] && {
      find "$N8N_DIR/binaryData" -type f -mmin +10 -delete 2>/dev/null || true
      find "$N8N_DIR/binaryData" -type d -empty -delete 2>/dev/null || true
    }
    sleep 600
  done
) &

# ── تنظيف DB كل ساعة ──
(
  sleep 3600
  while true; do
    [ -s "$N8N_DIR/database.sqlite" ] && {
      sqlite3 "$N8N_DIR/database.sqlite" "
        DELETE FROM execution_entity;
        DELETE FROM execution_data WHERE executionId NOT IN (SELECT id FROM execution_entity);
        DROP TABLE IF EXISTS execution_metadata;
        DROP TABLE IF EXISTS workflow_statistics;
        VACUUM;
      " 2>/dev/null || true
    }
    sleep 3600
  done
) &

echo "🚀 تشغيل n8n..."
exec n8n start
