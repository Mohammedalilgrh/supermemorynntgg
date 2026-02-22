#!/bin/sh
set -e

TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"
TG_CHAT_ID="${TG_CHAT_ID:-}"

if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then
  exit 0
fi

N8N_DIR="/home/node/.n8n"
TMP="/tmp/backup_$$"
TG="https://api.telegram.org/bot${TG_BOT_TOKEN}"

mkdir -p "$TMP"

if [ ! -f "$N8N_DIR/database.sqlite" ]; then
  exit 0
fi

sqlite3 "$N8N_DIR/database.sqlite" "PRAGMA wal_checkpoint(TRUNCATE);" 2>/dev/null || true

sqlite3 "$N8N_DIR/database.sqlite" ".dump" | gzip -1 > "$TMP/db.sql.gz"

if [ ! -s "$TMP/db.sql.gz" ]; then
  rm -rf "$TMP"
  exit 1
fi

ID=$(date +"%Y-%m-%d_%H-%M-%S")

RESP=$(curl -s -X POST "${TG}/sendDocument" \
  -F "chat_id=${TG_CHAT_ID}" \
  -F "document=@${TMP}/db.sql.gz" \
  -F "caption=#n8n_backup ${ID}")

MSG_ID=$(echo "$RESP" | jq -r '.result.message_id // empty')

if [ -n "$MSG_ID" ]; then
  curl -s -X POST "${TG}/pinChatMessage" \
    -d "chat_id=${TG_CHAT_ID}" \
    -d "message_id=${MSG_ID}" \
    -d "disable_notification=true" >/dev/null 2>&1 || true
fi

rm -rf "$TMP"
