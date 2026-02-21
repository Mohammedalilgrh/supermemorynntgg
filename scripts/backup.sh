#!/bin/sh
set -e

: "${TG_BOT_TOKEN:?}"
: "${TG_CHAT_ID:?}"

N8N_DIR="/home/node/.n8n"
TMP="/tmp/backup_$$"
TG="https://api.telegram.org/bot${TG_BOT_TOKEN}"

mkdir -p "$TMP"

echo "📦 Creating backup..."

sqlite3 "$N8N_DIR/database.sqlite" ".timeout 10000" "PRAGMA wal_checkpoint(TRUNCATE);" || true

sqlite3 "$N8N_DIR/database.sqlite" ".dump" | gzip -1 > "$TMP/db.sql.gz"

if [ ! -s "$TMP/db.sql.gz" ]; then
  echo "❌ Backup failed"
  exit 1
fi

ID=$(date +"%Y-%m-%d_%H-%M-%S")

curl -s -X POST "${TG}/sendDocument" \
  -F "chat_id=${TG_CHAT_ID}" \
  -F "document=@${TMP}/db.sql.gz" \
  -F "caption=#n8n_backup ${ID}" >/dev/null

rm -rf "$TMP"

echo "✅ Backup sent"
