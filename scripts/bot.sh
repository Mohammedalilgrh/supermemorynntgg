#!/bin/sh
set -eu

: "${TG_BOT_TOKEN:?}"
: "${TG_CHAT_ID:?}"
: "${TG_ADMIN_ID:?}"

N8N_DIR="${N8N_DIR:-/home/node/.n8n}"
WORK="${WORK:-/backup-data}"
HIST="$WORK/history"
TG="https://api.telegram.org/bot${TG_BOT_TOKEN}"

# ملف الـ offset
OFFSET_FILE="$WORK/.bot_offset"
mkdir -p "$HIST"

# قراءة الـ offset
get_offset() {
  if [ -f "$OFFSET_FILE" ]; then
    cat "$OFFSET_FILE"
  else
    echo "0"
  fi
}

# حفظ الـ offset
save_offset() {
  echo "$1" > "$OFFSET_FILE"
}

# ══════════════════════════════
# دوال الإرسال (نفسها)
# ══════════════════════════════

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
    -d "callback_query_id=$1" -d "text=${2:-✓}" >/dev/null 2>&1 || true
}

# ══════════════════════════════
# القائمة الرئيسية
# ══════════════════════════════

MAIN_MENU='{
  "inline_keyboard": [
    [{"text":"📊 حالة النظام","callback_data":"status"}],
    [{"text":"💾 حفظ الآن!","callback_data":"backup_now"}],
    [{"text":"📋 قائمة النسخ","callback_data":"list_backups"}],
    [{"text":"🔄 استرجاع","callback_data":"restore_menu"}],
    [{"text":"🗑️ تنظيف","callback_data":"cleanup"}],
    [{"text":"ℹ️ معلومات","callback_data":"info"}]
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
  _last_bkp="—"
  _total_bkps=$(ls "$HIST"/*.json 2>/dev/null | wc -l || echo 0)

  if [ -f "$_db" ]; then
    _db_size=$(du -h "$_db" 2>/dev/null | cut -f1)
    _db_tables=$(sqlite3 "$_db" "SELECT count(*) FROM sqlite_master WHERE type='table';" 2>/dev/null || echo 0)
  fi

  if [ -f "$WORK/.backup_state" ]; then
    _last_bkp=$(grep '^ID=' "$WORK/.backup_state" 2>/dev/null | cut -d= -f2)
  fi

  send_keyboard "📊 <b>حالة النظام</b>

🗄️ DB: <code>$_db_size</code> | $_db_tables جداول
💾 آخر نسخة: <code>$_last_bkp</code>
📦 المجموع: <code>$_total_bkps</code> نسخة
🕒 الوقت: <code>$(date '+%Y-%m-%d %H:%M')</code>" "$MAIN_MENU"
}

# ══════════════════════════════
# حفظ فوري
# ══════════════════════════════

do_backup_now() {
  send_msg "⏳ جاري الحفظ..."
  rm -f "$WORK/.backup_state"
  
  if sh /scripts/backup.sh >/dev/null 2>&1; then
    _id=$(grep '^ID=' "$WORK/.backup_state" 2>/dev/null | cut -d= -f2 || echo "?")
    send_keyboard "✅ <b>تم الحفظ!</b>
🆔 <code>$_id</code>" "$MAIN_MENU"
  else
    send_keyboard "❌ فشل الحفظ" "$MAIN_MENU"
  fi
}

# ══════════════════════════════
# قائمة النسخ + استرجاع
# ══════════════════════════════

do_list_backups() {
  _list=""
  _kb='{"inline_keyboard":['
  _count=0

  for f in $(ls -t "$HIST"/*.json 2>/dev/null | head -10); do
    [ -f "$f" ] || continue
    _count=$((_count + 1))
    _bid=$(jq -r '.id // "?"' "$f" 2>/dev/null)
    _bts=$(jq -r '.timestamp // "?"' "$f" 2>/dev/null)
    _fn=$(basename "$f" .json)

    _list="${_list}${_count}. <code>${_bid}</code>
   📅 ${_bts}
"
    _kb="${_kb}[{\"text\":\"🔄 ${_count}. ${_bid:0:16}...\",\"callback_data\":\"confirm_restore_${_fn}\"}],"
  done

  [ "$_count" -eq 0 ] && {
    send_keyboard "📋 لا توجد نسخ" "$MAIN_MENU"
    return
  }

  _kb="${_kb}[{\"text\":\"🔙 الرئيسية\",\"callback_data\":\"main\"}]]}"

  send_keyboard "📋 <b>آخر $_count نسخ:</b>

$_list
⚠️ اضغط للاسترجاع (يحذف البيانات الحالية!)" "$_kb"
}

# ══════════════════════════════
# استرجاع
# ══════════════════════════════

do_restore_confirm() {
  _fname="$1"
  _file="$HIST/${_fname}.json"

  [ ! -f "$_file" ] && {
    send_msg "❌ النسخة غير موجودة"
    show_main
    return
  }

  _bid=$(jq -r '.id // "?"' "$_file" 2>/dev/null)

  send_msg "⏳ <b>جاري الاسترجاع...</b>
🆔 $_bid
⏱️ انتظر دقيقة..."

  _tmp="/tmp/restore_$$"
  rm -rf "$_tmp"
  mkdir -p "$_tmp"

  # تحميل الملفات
  _failed=""
  jq -c '.files[]' "$_file" 2>/dev/null | while read -r obj; do
    _fid=$(echo "$obj" | jq -r '.file_id // .f // empty')
    _fname=$(echo "$obj" | jq -r '.name // .n // empty')
    _mid=$(echo "$obj" | jq -r '.msg_id // .m // 0')

    [ -z "$_fid" ] && continue

    # محاولة 1: file_id
    _path=$(curl -sS "${TG}/getFile?file_id=${_fid}" 2>/dev/null \
      | jq -r '.result.file_path // empty')

    if [ -n "$_path" ]; then
      curl -sS -o "$_tmp/$_fname" \
        "https://api.telegram.org/file/bot${TG_BOT_TOKEN}/${_path}" 2>/dev/null || true
    fi

    # محاولة 2: forward
    if [ ! -s "$_tmp/$_fname" ] && [ "$_mid" != "0" ]; then
      _fwd=$(curl -sS -X POST "${TG}/forwardMessage" \
        -d "chat_id=${TG_ADMIN_ID}" \
        -d "from_chat_id=${TG_CHAT_ID}" \
        -d "message_id=${_mid}" 2>/dev/null || true)

      _new_fid=$(echo "$_fwd" | jq -r '.result.document.file_id // empty')
      _fwd_mid=$(echo "$_fwd" | jq -r '.result.message_id // empty')

      [ -n "$_fwd_mid" ] && curl -sS -X POST "${TG}/deleteMessage" \
        -d "chat_id=${TG_ADMIN_ID}" -d "message_id=${_fwd_mid}" >/dev/null 2>&1 || true

      if [ -n "$_new_fid" ]; then
        _path=$(curl -sS "${TG}/getFile?file_id=${_new_fid}" 2>/dev/null \
          | jq -r '.result.file_path // empty')
        [ -n "$_path" ] && curl -sS -o "$_tmp/$_fname" \
          "https://api.telegram.org/file/bot${TG_BOT_TOKEN}/${_path}" 2>/dev/null || true
      fi
    fi

    [ ! -s "$_tmp/$_fname" ] && _failed="yes"
    sleep 1
  done

  # استرجاع
  if [ -f "$_tmp/db.sql.gz" ]; then
    sqlite3 "$N8N_DIR/database.sqlite" "PRAGMA wal_checkpoint(TRUNCATE);" 2>/dev/null || true
    rm -f "$N8N_DIR/database.sqlite"*
    gzip -dc "$_tmp/db.sql.gz" | sqlite3 "$N8N_DIR/database.sqlite"
  elif ls "$_tmp"/db.sql.gz.part_* >/dev/null 2>&1; then
    sqlite3 "$N8N_DIR/database.sqlite" "PRAGMA wal_checkpoint(TRUNCATE);" 2>/dev/null || true
    rm -f "$N8N_DIR/database.sqlite"*
    cat "$_tmp"/db.sql.gz.part_* | gzip -dc | sqlite3 "$N8N_DIR/database.sqlite"
  fi

  if [ -f "$_tmp/files.tar.gz" ]; then
    gzip -dc "$_tmp/files.tar.gz" | tar -C "$N8N_DIR" -xf - 2>/dev/null || true
  elif ls "$_tmp"/files.tar.gz.part_* >/dev/null 2>&1; then
    cat "$_tmp"/files.tar.gz.part_* | gzip -dc | tar -C "$N8N_DIR" -xf - 2>/dev/null || true
  fi

  rm -rf "$_tmp"

  if [ -s "$N8N_DIR/database.sqlite" ]; then
    _tc=$(sqlite3 "$N8N_DIR/database.sqlite" \
      "SELECT count(*) FROM sqlite_master WHERE type='table';" 2>/dev/null || echo 0)
    send_keyboard "✅ <b>تم الاسترجاع!</b>
📋 $_tc جداول

⚠️ <b>أعد تشغيل n8n من Render</b>" "$MAIN_MENU"
  else
    send_keyboard "❌ فشل الاسترجاع" "$MAIN_MENU"
  fi
}

# ══════════════════════════════
# تنظيف
# ══════════════════════════════

do_cleanup() {
  _total=$(ls "$HIST"/*.json 2>/dev/null | wc -l || echo 0)
  [ "$_total" -le 5 ] && {
    send_keyboard "✅ لا حاجة للتنظيف
عدد النسخ: $_total" "$MAIN_MENU"
    return
  }

  _deleted=0
  for f in $(ls -t "$HIST"/*.json 2>/dev/null | tail -n +6); do
    rm -f "$f"
    _deleted=$((_deleted + 1))
  done

  send_keyboard "🗑️ تم حذف $_deleted نسخة قديمة
✅ باقي 5 نسخ" "$MAIN_MENU"
}

# ══════════════════════════════
# معلومات
# ══════════════════════════════

do_info() {
  send_keyboard "ℹ️ <b>معلومات النظام</b>

🌐 n8n: <code>${N8N_HOST:-N/A}</code>
📱 Chat: <code>${TG_CHAT_ID}</code>
⏱️ فحص كل: <code>${MONITOR_INTERVAL:-30}s</code>

📝 <b>الأوامر:</b>
/start - القائمة
/status - الحالة
/backup - حفظ فوري
/list - قائمة النسخ" "$MAIN_MENU"
}

# ══════════════════════════════
# معالج الأوامر
# ══════════════════════════════

handle_message() {
  _text="$1"
  _from="$2"

  [ "$_from" != "$TG_ADMIN_ID" ] && return

  case "$_text" in
    /start|/menu) show_main ;;
    /status) do_status ;;
    /backup) do_backup_now ;;
    /list) do_list_backups ;;
    /info) do_info ;;
  esac
}

handle_callback() {
  _data="$1"
  _cb_id="$2"
  _from="$3"

  [ "$_from" != "$TG_ADMIN_ID" ] && return

  answer_callback "$_cb_id"

  case "$_data" in
    main) show_main ;;
    status) do_status ;;
    backup_now) do_backup_now ;;
    list_backups) do_list_backups ;;
    restore_menu) do_list_backups ;;
    cleanup) do_cleanup ;;
    info) do_info ;;
    confirm_restore_*)
      _fname=$(echo "$_data" | sed 's/^confirm_restore_//')
      do_restore_confirm "$_fname"
      ;;
  esac
}

# ══════════════════════════════
# حلقة رئيسية (مُصلحة!)
# ══════════════════════════════

echo "🤖 البوت جاهز..."

while true; do
  CURRENT_OFFSET=$(get_offset)
  
  UPDATES=$(curl -sS "${TG}/getUpdates?offset=${CURRENT_OFFSET}&timeout=25" 2>/dev/null || echo '{"ok":false}')

  OK=$(echo "$UPDATES" | jq -r '.ok // "false"' 2>/dev/null)
  [ "$OK" != "true" ] && { sleep 5; continue; }

  RESULTS=$(echo "$UPDATES" | jq -c '.result[]' 2>/dev/null)
  [ -z "$RESULTS" ] && continue

  # معالجة كل update
  echo "$RESULTS" | while read -r update; do
    _uid=$(echo "$update" | jq -r '.update_id')
    
    # رسالة نصية
    _msg_text=$(echo "$update" | jq -r '.message.text // empty')
    _msg_from=$(echo "$update" | jq -r '.message.from.id // 0')
    
    if [ -n "$_msg_text" ]; then
      handle_message "$_msg_text" "$_msg_from"
    fi

    # callback
    _cb_data=$(echo "$update" | jq -r '.callback_query.data // empty')
    _cb_id=$(echo "$update" | jq -r '.callback_query.id // empty')
    _cb_from=$(echo "$update" | jq -r '.callback_query.from.id // 0')

    if [ -n "$_cb_data" ]; then
      handle_callback "$_cb_data" "$_cb_id" "$_cb_from"
    fi

    # حفظ الـ offset
    NEW_OFFSET=$((_uid + 1))
    save_offset "$NEW_OFFSET"
  done

done
