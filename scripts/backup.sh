#!/bin/sh
set -e

: "${TG_BOT_TOKEN:?}"
: "${TG_CHAT_ID:?}"

N8N_DIR="/home/node/.n8n"
TMP="/tmp/db_backup_$$"
TG="https://api.telegram.org/bot${TG_BOT_TOKEN}"

mkdir -p "$TMP"

if [ ! -f "$N8N_DIR/database.sqlite" ]; then
  exit 0
fi

sqlite3 "$N8N_DIR/database.sqlite" \
  "PRAGMA wal_checkpoint(TRUNCATE);" || true

sqlite3 "$N8N_DIR/database.sqlite" ".dump" \
  | gzip -1 > "$TMP/db.sql.gz"

[ -s "$TMP/db.sql.gz" ] || exit 1

ID=$(date +"%Y-%m-%d_%H-%M-%S")

RESP=$(curl -s -X POST "${TG}/sendDocument" \
  -F "chat_id=${TG_CHAT_ID}" \
  -F "document=@${TMP}/db.sql.gz" \
  -F "caption=#n8n_backup ${ID}")

MSG_ID=$(echo "$RESP" | jq -r '.result.message_id')

# Pin newest
curl -s -X POST "${TG}/pinChatMessage" \
  -d "chat_id=${TG_CHAT_ID}" \
  -d "message_id=${MSG_ID}" \
  -d "disable_notification=true" >/dev/null

rm -rf "$TMP"
