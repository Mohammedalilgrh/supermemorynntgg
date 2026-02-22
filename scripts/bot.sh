#!/bin/sh
set -eu

: "${TG_BOT_TOKEN:?}"
: "${TG_CHAT_ID:?}"
: "${TG_ADMIN_ID:?}"

N8N_DIR="${N8N_DIR:-/home/node/.n8n}"
WORK="${WORK:-/backup-data}"

TG="https://api.telegram.org/bot${TG_BOT_TOKEN}"
OFFSET=0

# ══════════════════════════════
# دوال الإرسال
# ══════════════════════════════

send_msg() {
  curl -sS -X POST "${TG}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "{
      \"chat_id\": ${TG_ADMIN_ID},
      \"text\": \"$1\",
      \"parse_mode\": \"HTML\"
    }" 2>/dev/null || true
}

send_keyboard() {
  _text="$1"
  _kb="$2"
  curl -sS -X POST "${TG}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "{
      \"chat_id\": ${TG_ADMIN_ID},
      \"text\": \"$_text\",
      \"parse_mode\": \"HTML\",
      \"reply_markup\": $_kb
    }" 2>/dev/null || true
}

answer_callback() {
  curl -sS -X POST "${TG}/answerCallbackQuery" \
    -d "callback_query_id=$1" \
    -d "text=${2:-}" >/dev/null 2>&1 || true
}

# ══════════════════════════════
# القائمة الرئيسية
# ══════════════════════════════

MAIN_MENU='{
  "inline_keyboard": [
    [{"text": "📊 حالة النظام", "callback_data": "status"}],
    [{"text": "💾 حفظ الآن!", "callback_data": "backup_now"}],
    [{"text": "ℹ️ معلومات", "callback_data": "info"}]
  ]
}'

show_main() {
  send_keyboard "🤖 <b>لوحة التحكم - n8n Backup</b>

اختار العملية:" "$MAIN_MENU"
}

# ══════════════════════════════
# حالة النظام
# ══════════════════════════════

do_status() {
  _db="$N8N_DIR/database.sqlite"
  _db_size="لا يوجد"
  _db_tables=0
  _db_time="—"
  _last_bkp="لا يوجد"
  _last_time="—"
  _last_size="—"

  if [ -f "$_db" ]; then
    _db_size=$(du -h "$_db" 2>/dev/null | cut -f1)
    _db_tables=$(sqlite3 "$_db" "SELECT count(*) FROM sqlite_master WHERE type='table';" 2>/dev/null || echo 0)
    _ts=$(stat -c '%Y' "$_db" 2>/dev/null || echo 0)
    _db_time=$(date -d "@$_ts" "+%Y-%m-%d %H:%M" 2>/dev/null || date -u "+%Y-%m-%d %H:%M")
  fi

  if [ -f "$WORK/.backup_state" ]; then
    _last_bkp=$(grep '^ID=' "$WORK/.backup_state" 2>/dev/null | cut -d= -f2 || echo "—")
    _last_time=$(grep '^TS=' "$WORK/.backup_state" 2>/dev/null | cut -d= -f2 || echo "—")
    _last_size=$(grep '^SZ=' "$WORK/.backup_state" 2>/dev/null | cut -d= -f2 || echo "—")
  fi

  send_keyboard "📊 <b>حالة النظام</b>

🗄️ <b>قاعدة البيانات:</b>
  📦 الحجم: <code>$_db_size</code>
  📋 الجداول: <code>$_db_tables</code>
  🕒 آخر تعديل: <code>$_db_time</code>

💾 <b>آخر باك أب:</b>
  📌 <code>$_last_bkp</code>
  🕒 <code>$_last_time</code>
  📦 <code>$_last_size</code>

⏰ الآن: <code>$(date -u '+%Y-%m-%d %H:%M:%S UTC')</code>" "$MAIN_MENU"
}

# ══════════════════════════════
# حفظ فوري
# ══════════════════════════════

do_backup_now() {
  send_msg "⏳ <b>جاري الحفظ...</b>"

  rm -f "$WORK/.backup_state"
  _output=$(sh /scripts/backup.sh 2>&1 || true)

  if echo "$_output" | grep -q "اكتمل"; then
    _id=$(grep '^ID=' "$WORK/.backup_state" 2>/dev/null | cut -d= -f2 || echo "?")
    _sz=$(grep '^SZ=' "$WORK/.backup_state" 2>/dev/null | cut -d= -f2 || echo "?")
    send_keyboard "✅ <b>تم الحفظ!</b>

🆔 <code>$_id</code>
📦 <code>$_sz</code>" "$MAIN_MENU"
  else
    send_keyboard "❌ <b>فشل الحفظ</b>

<pre>$(echo "$_output" | tail -5)</pre>" "$MAIN_MENU"
  fi
}

# ══════════════════════════════
# معلومات
# ══════════════════════════════

do_info() {
  send_keyboard "ℹ️ <b>معلومات النظام</b>

🌐 <b>n8n:</b> <code>https://${N8N_HOST:-localhost}</code>
📱 <b>Channel:</b> <code>${TG_CHAT_ID}</code>

⏱️ <b>إعدادات:</b>
  فحص كل: <code>${MONITOR_INTERVAL:-30}s</code>
  إجباري كل: <code>${FORCE_BACKUP_EVERY_SEC:-900}s</code>
  حجم القطعة: <code>${CHUNK_SIZE:-18M}</code>

💡 <b>النظام يحفظ بس db.sql.gz</b>
  = كل الـ workflows + credentials + إعدادات

📝 <b>الأوامر:</b>
  /start - القائمة
  /status - الحالة
  /backup - حفظ فوري" "$MAIN_MENU"
}

# ══════════════════════════════
# حلقة الاستماع
# ══════════════════════════════

echo "🤖 البوت جاهز..."

while true; do
  UPDATES=$(curl -sS "${TG}/getUpdates?offset=${OFFSET}&timeout=30" 2>/dev/null || true)
  [ -n "$UPDATES" ] || { sleep 5; continue; }

  OK=$(echo "$UPDATES" | jq -r '.ok // "false"' 2>/dev/null)
  [ "$OK" = "true" ] || { sleep 5; continue; }

  RESULTS=$(echo "$UPDATES" | jq -r '.result // []' 2>/dev/null)
  [ "$RESULTS" != "[]" ] || continue

  echo "$RESULTS" | jq -c '.[]' 2>/dev/null | while read -r update; do
    _uid=$(echo "$update" | jq -r '.update_id' 2>/dev/null)
    OFFSET=$((_uid + 1))

    # ── رسالة نصية ──
    _text=$(echo "$update" | jq -r '.message.text // empty' 2>/dev/null)
    _from=$(echo "$update" | jq -r '.message.from.id // 0' 2>/dev/null)

    if [ -n "$_text" ] && [ "$_from" = "$TG_ADMIN_ID" ]; then
      case "$_text" in
        /start|/menu) show_main ;;
        /status) do_status ;;
        /backup|/save) do_backup_now ;;
        /info|/help) do_info ;;
      esac
    fi

    # ── Callback ──
    _cb_id=$(echo "$update" | jq -r '.callback_query.id // empty' 2>/dev/null)
    _cb_data=$(echo "$update" | jq -r '.callback_query.data // empty' 2>/dev/null)
    _cb_from=$(echo "$update" | jq -r '.callback_query.from.id // 0' 2>/dev/null)

    if [ -n "$_cb_id" ] && [ "$_cb_from" = "$TG_ADMIN_ID" ]; then
      answer_callback "$_cb_id" "⏳"

      case "$_cb_data" in
        main) show_main ;;
        status) do_status ;;
        backup_now) do_backup_now ;;
        info) do_info ;;
      esac
    fi
  done

  _last=$(echo "$RESULTS" | jq -r '.[-1].update_id // empty' 2>/dev/null)
  [ -n "$_last" ] && OFFSET=$((_last + 1))
done
