#!/bin/sh
set -e

: "${TG_BOT_TOKEN:?}"
: "${TG_ADMIN_ID:?}"

TG="https://api.telegram.org/bot${TG_BOT_TOKEN}"
OFFSET=0

while true; do
  RESP=$(curl -s "${TG}/getUpdates?offset=${OFFSET}&timeout=25")

  echo "$RESP" | jq -c '.result[]?' | while read -r update; do
    UPDATE_ID=$(echo "$update" | jq -r '.update_id')
    OFFSET=$((UPDATE_ID + 1))

    TEXT=$(echo "$update" | jq -r '.message.text // empty')
    FROM=$(echo "$update" | jq -r '.message.from.id // 0')

    [ "$FROM" = "$TG_ADMIN_ID" ] || continue

    case "$TEXT" in
      /backup)
        sh /scripts/backup.sh
        curl -s -X POST "${TG}/sendMessage" \
          -d "chat_id=${TG_ADMIN_ID}" \
          -d "text=✅ Backup done" >/dev/null
        ;;
      /restore)
        sh /scripts/restore.sh
        curl -s -X POST "${TG}/sendMessage" \
          -d "chat_id=${TG_ADMIN_ID}" \
          -d "text=✅ Restored (restart needed)" >/dev/null
        ;;
      /status)
        curl -s -X POST "${TG}/sendMessage" \
          -d "chat_id=${TG_ADMIN_ID}" \
          -d "text=✅ n8n running" >/dev/null
        ;;
    esac
  done

  sleep 3
done
