#!/bin/sh
set -eu

: "${TG_BOT_TOKEN:?}"
: "${TG_CHAT_ID:?}"
: "${TG_ADMIN_ID:?}"

N8N_DIR="${N8N_DIR:-/home/node/.n8n}"
WORK="${WORK/-/backup-data}"
WORK="${WORK:-/backup-data}"
TG="https://api.telegram.org/bot${TG_BOT_TOKEN}"

# FIX #6: path ثابت بدل PID — يبقى نفسه حتى لو crash وrestart
OFFSET_FILE="/tmp/tg_bot_offset"
UPDATES_FILE="/tmp/tg_bot_updates"
[ -f "$OFFSET_FILE" ] || echo "0" > "$OFFSET_FILE"

send_msg() {
  curl -sS -X POST "${TG}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "{\"chat_id\":${TG_ADMIN_ID},\"text\":\"$1\",\"parse_mode\":\"HTML\"}" \
    2>/dev/null || true
}

send_keyboard() {
  curl -sS -X POST "${TG}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "{\"chat_id\":${TG_ADMIN_ID},\"text\":\"$1\",\"parse_mode\":\"HTML\",\"reply_markup\":$2}" \
    2>/dev/null || true
}

answer_callback() {
  curl -sS -X POST "${TG}/answerCallbackQuery" \
    -d "callback_query_id=$1" -d "text=${2:-}" >/dev/null 2>&1 || true
}

MAIN_MENU='{
  "inline_keyboard": [
    [{"text": "📊 الحالة", "callback_data": "status"}],
    [{"text": "💾 حفظ الآن", "callback_data": "backup_now"}],
    [{"text": "🧹 تنظيف", "callback_data": "cleanup"}],
    [{"text": "ℹ️ معلومات", "callback_data": "info"}]
  ]
}'

show_main() {
  send_keyboard "🤖 <b>لوحة التحكم</b>\n\nاختار:" "$MAIN_MENU"
}

do_status() {
  _db="$N8N_DIR/database.sqlite"
  _db_size="—"; _db_tables=0; _bin_size="0"; _last_bkp="—"; _last_size="—"
  [ -f "$_db" ] && {
    _db_size=$(du -h "$_db" 2>/dev/null | cut -f1)
    _db_tables=$(sqlite3 "$_db" "SELECT count(*) FROM sqlite_master WHERE type='table';" 2>/dev/null || echo 0)
  }
  [ -d "$N8N_DIR/binaryData" ] && \
    _bin_size=$(du -sm "$N8N_DIR/binaryData" 2>/dev/null | cut -f1 || echo 0)
  [ -f "$WORK/.backup_state" ] && {
    _last_bkp=$(grep '^ID=' "$WORK/.backup_state" 2>/dev/null | cut -d= -f2 || echo "—")
    _last_size=$(grep '^SZ=' "$WORK/.backup_state" 2>/dev/null | cut -d= -f2 || echo "—")
  }
  send_keyboard "📊 <b>الحالة</b>\n\n🗄️ DB: <code>$_db_size</code> ($_db_tables جدول)\n📁 Binary: <code>${_bin_size}MB</code>\n💾 آخر باك أب: <code>$_last_bkp</code> ($_last_size)\n⏰ <code>$(date -u '+%H:%M:%S UTC')</code>" "$MAIN_MENU"
}

do_backup_now() {
  send_msg "⏳ جاري الحفظ..."
  rm -f "$WORK/.backup_state"
  _out=$(sh /scripts/backup.sh 2>&1 || true)
  if echo "$_out" | grep -q "اكتمل"; then
    _id=$(grep '^ID=' "$WORK/.backup_state" 2>/dev/null | cut -d= -f2 || echo "?")
    _sz=$(grep '^SZ=' "$WORK/.backup_state" 2>/dev/null | cut -d= -f2 || echo "?")
    send_keyboard "✅ تم! <code>$_id</code> ($_sz)" "$MAIN_MENU"
  else
    send_keyboard "❌ فشل" "$MAIN_MENU"
  fi
}

do_cleanup() {
  _before=0
  [ -d "$N8N_DIR/binaryData" ] && \
    _before=$(du -sm "$N8N_DIR/binaryData" 2>/dev/null | cut -f1 || echo 0)
  find "$N8N_DIR/binaryData" -type f -delete 2>/dev/null || true
  find "$N8N_DIR/binaryData" -type d -empty -delete 2>/dev/null || true
  _db_before=$(du -h "$N8N_DIR/database.sqlite" 2>/dev/null | cut -f1 || echo "—")
  sqlite3 "$N8N_DIR/database.sqlite" "
    DELETE FROM execution_entity;
    DELETE FROM execution_data WHERE executionId NOT IN (SELECT id FROM execution_entity);
    DROP TABLE IF EXISTS execution_metadata;
    DROP TABLE IF EXISTS workflow_statistics;
    VACUUM;
  " 2>/dev/null || true
  _db_after=$(du -h "$N8N_DIR/database.sqlite" 2>/dev/null | cut -f1 || echo "—")
  send_keyboard "🧹 <b>تنظيف تم!</b>\n\n📁 Binary: <code>${_before}MB → 0MB</code>\n🗄️ DB: <code>$_db_before → $_db_after</code>" "$MAIN_MENU"
}

do_info() {
  send_keyboard "ℹ️ <b>المعلومات</b>\n\n💡 يحفظ <code>db.sql.gz</code>\n= workflows + credentials + إعدادات\n\n📤 <b>باك أب:</b>\n  فحص كل 5 دقائق\n  أقل فترة: 10 دقائق\n  إجباري: كل 6 ساعات\n\n📝 /start /status /backup /clean" "$MAIN_MENU"
}

echo "🤖 البوت جاهز..."

while true; do
  OFFSET=$(cat "$OFFSET_FILE" 2>/dev/null || echo 0)
  UPDATES=$(curl -sS "${TG}/getUpdates?offset=${OFFSET}&timeout=30" 2>/dev/null || true)
  [ -n "$UPDATES" ] || { sleep 5; continue; }

  OK=$(echo "$UPDATES" | jq -r '.ok // "false"' 2>/dev/null)
  [ "$OK" = "true" ] || { sleep 5; continue; }

  RESULTS=$(echo "$UPDATES" | jq -r '.result // []' 2>/dev/null)
  [ "$RESULTS" != "[]" ] || continue

  # FIX #7: path ثابت للـ updates file
  echo "$RESULTS" | jq -c '.[]' 2>/dev/null > "$UPDATES_FILE" || true

  while IFS= read -r update; do
    _uid=$(echo "$update" | jq -r '.update_id' 2>/dev/null)
    echo $((_uid + 1)) > "$OFFSET_FILE"

    _text=$(echo "$update" | jq -r '.message.text // empty' 2>/dev/null)
    _from=$(echo "$update" | jq -r '.message.from.id // 0' 2>/dev/null)
    if [ -n "$_text" ] && [ "$_from" = "$TG_ADMIN_ID" ]; then
      case "$_text" in
        /start|/menu)  show_main ;;
        /status)       do_status ;;
        /backup|/save) do_backup_now ;;
        /info|/help)   do_info ;;
        /clean*)       do_cleanup ;;
      esac
    fi

    _cb_id=$(echo "$update" | jq -r '.callback_query.id // empty' 2>/dev/null)
    _cb_data=$(echo "$update" | jq -r '.callback_query.data // empty' 2>/dev/null)
    _cb_from=$(echo "$update" | jq -r '.callback_query.from.id // 0' 2>/dev/null)
    if [ -n "$_cb_id" ] && [ "$_cb_from" = "$TG_ADMIN_ID" ]; then
      answer_callback "$_cb_id" "⏳"
      case "$_cb_data" in
        main)       show_main ;;
        status)     do_status ;;
        backup_now) do_backup_now ;;
        cleanup)    do_cleanup ;;
        info)       do_info ;;
      esac
    fi
  done < "$UPDATES_FILE"

  _last=$(echo "$RESULTS" | jq -r '.[-1].update_id // empty' 2>/dev/null)
  [ -n "$_last" ] && echo $((_last + 1)) > "$OFFSET_FILE"
done
