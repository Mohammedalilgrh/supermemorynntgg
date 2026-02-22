#!/bin/sh
set -e

TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"
TG_CHAT_ID="${TG_CHAT_ID:-}"

if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then
  exit 0
fi

N8N_DIR="/home/node/.n8n"
TMP="/tmp/restore_$$"
TG="https://api.telegram.org/bot${TG_BOT_TOKEN}"

mkdir -p "$TMP"

PIN=$(curl -s "${TG}/getChat?chat_id=${TG_CHAT_ID}")
FILE_ID=$(echo "$PIN" | jq -r '.result.pinned_message.document.file_id // empty')

if [ -z "$FILE_ID" ]; then
  rm -rf "$TMP"
  exit 0
fi

FILE_PATH=$(curl -s "${TG}/getFile?file_id=${FILE_ID}" | jq -r '.result.file_path // empty')

if [ -z "$FILE_PATH" ]; then
  rm -rf "$TMP"
  exit 0
fi

curl -s -o "$TMP/db.sql.gz" "https://api.telegram.org/file/bot${TG_BOT_TOKEN}/${FILE_PATH}"

if [ ! -s "$TMP/db.sql.gz" ]; then
  rm -rf "$TMP"
  exit 0
fi

gunzip -c "$TMP/db.sql.gz" | sqlite3 "$N8N_DIR/database.sqlite"

rm -rf "$TMP"
