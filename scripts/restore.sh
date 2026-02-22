#!/bin/sh
set -e

: "${TG_BOT_TOKEN:?}"
: "${TG_CHAT_ID:?}"

N8N_DIR="/home/node/.n8n"
TMP="/tmp/db_restore_$$"
TG="https://api.telegram.org/bot${TG_BOT_TOKEN}"

mkdir -p "$TMP"

PIN=$(curl -s "${TG}/getChat?chat_id=${TG_CHAT_ID}")
FILE_ID=$(echo "$PIN" | jq -r '.result.pinned_message.document.file_id // empty')

[ -n "$FILE_ID" ] || exit 0

FILE_PATH=$(curl -s "${TG}/getFile?file_id=${FILE_ID}" | jq -r '.result.file_path')

curl -s -o "$TMP/db.sql.gz" \
  "https://api.telegram.org/file/bot${TG_BOT_TOKEN}/${FILE_PATH}"

[ -s "$TMP/db.sql.gz" ] || exit 1

gzip -dc "$TMP/db.sql.gz" | sqlite3 "$N8N_DIR/database.sqlite"

rm -rf "$TMP"
