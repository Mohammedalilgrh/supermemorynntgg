#!/bin/sh
set -eu

: "${TG_BOT_TOKEN:?}"
: "${TG_CHAT_ID:?}"
: "${TG_ADMIN_ID:?}"

N8N_DIR="${N8N_DIR:-/home/node/.n8n}"
WORK="${WORK:-/backup-data}"
HIST="$WORK/history"

TG="https://api.telegram.org/bot${TG_BOT_TOKEN}"
OFFSET=0

mkdir -p "$HIST"

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
  _cbid="$1"
  _text="${2:-}"
  curl -sS -X POST "${TG}/answerCallbackQuery" \
    -d "callback_query_id=${_cbid}" \
    -d "text=${_text}" >/dev/null 2>&1 || true
}

edit_msg() {
  _chatid="$1"
  _msgid="$2"
  _text="$3"
  _kb="${4:-}"

  if [ -n "$_kb" ]; then
    curl -sS -X POST "${TG}/editMessageText" \
      -H "Content-Type: application/json" \
      -d "{
        \"chat_id\": $_chatid,
        \"message_id\": $_msgid,
        \"text\": \"$_text\",
        \"parse_mode\": \"HTML\",
        \"reply_markup\": $_kb
      }" 2>/dev/null || true
  else
    curl -sS -X POST "${TG}/editMessageText" \
      -H "Content-Type: application/json" \
      -d "{
        \"chat_id\": $_chatid,
        \"message_id\": $_msgid,
        \"text\": \"$_text\",
        \"parse_mode\": \"HTML\"
      }" 2>/dev/null || true
  fi
}

# ══════════════════════════════
# القائمة الرئيسية
# ══════════════════════════════

MAIN_MENU='{
  "inline_keyboard": [
    [{"text": "📊 حالة النظام", "callback_data": "status"}],
    [{"text": "💾 حفظ الآن!", "callback_data": "backup_now"}],
    [{"text": "📋 قائمة النسخ", "callback_data": "list_backups"}],
    [{"text": "📥 تحميل آخر نسخة", "callback_data": "download_latest"}],
    [{"text": "🗑️ حذف النسخ القديمة", "callback_data": "cleanup"}],
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
  _wal_size="0"
  _last_bkp="لا يوجد"
  _last_time="—"
  _total_bkps=0
  _uptime="—"

  if [ -f "$_db" ]; then
    _db_size=$(du -h "$_db" 2>/dev/null | cut -f1)
    _db_tables=$(sqlite3 "$_db" "SELECT count(*) FROM sqlite_master WHERE type='table';" 2>/dev/null || echo 0)
    _db_time=$(stat -c '%Y' "$_db" 2>/dev/null || echo 0)
    _db_time=$(date -d "@$_db_time" "+%Y-%m-%d %H:%M" 2>/dev/null || date -u "+%Y-%m-%d %H:%M")
  fi

  if [ -f "$_db-wal" ]; then
    _wal_size=$(du -h "$_db-wal" 2>/dev/null | cut -f1)
  fi

  if [ -f "$WORK/.backup_state" ]; then
    _last_bkp=$(grep '^ID=' "$WORK/.backup_state" 2>/dev/null | cut -d= -f2 || echo "—")
    _last_time=$(grep '^TS=' "$WORK/.backup_state" 2>/dev/null | cut -d= -f2 || echo "—")
  fi

  _total_bkps=$(ls "$HIST"/*.json 2>/dev/null | wc -l || echo 0)

  send_keyboard "📊 <b>حالة النظام</b>

🗄️ <b>قاعدة البيانات:</b>
  📦 الحجم: <code>$_db_size</code>
  📋 الجداول: <code>$_db_tables</code>
  📝 WAL: <code>$_wal_size</code>
  🕒 آخر تعديل: <code>$_db_time</code>

💾 <b>الباك أب:</b>
  📌 آخر نسخة: <code>$_last_bkp</code>
  🕒 الوقت: <code>$_last_time</code>
  📊 المجموع: <code>$_total_bkps</code> نسخة

⏰ الوقت الحالي: <code>$(date -u '+%Y-%m-%d %H:%M:%S UTC')</code>" "$MAIN_MENU"
}

# ══════════════════════════════
# حفظ فوري
# ══════════════════════════════

do_backup_now() {
  send_msg "⏳ <b>جاري الحفظ...</b>"

  # نمسح الحالة حتى يحفظ إجباري
  rm -f "$WORK/.backup_state"
  _output=$(sh /scripts/backup.sh 2>&1 || true)

  if echo "$_output" | grep -q "اكتمل"; then
    _id=$(grep '^ID=' "$WORK/.backup_state" 2>/dev/null | cut -d= -f2 || echo "?")
    send_keyboard "✅ <b>تم الحفظ بنجاح!</b>

🆔 <code>$_id</code>
🕒 <code>$(date -u '+%Y-%m-%d %H:%M:%S UTC')</code>" "$MAIN_MENU"
  else
    send_keyboard "❌ <b>فشل الحفظ</b>

<pre>$(echo "$_output" | tail -5)</pre>" "$MAIN_MENU"
  fi
}

# ══════════════════════════════
# قائمة النسخ
# ══════════════════════════════

do_list_backups() {
  _list=""
  _count=0
  _kb_buttons=""

  # نقرأ من ملفات التاريخ (آخر 10)
  for f in $(ls -t "$HIST"/*.json 2>/dev/null | head -10); do
    [ -f "$f" ] || continue
    _count=$((_count + 1))

    _bid=$(jq -r '.id // "?"' "$f" 2>/dev/null)
    _bts=$(jq -r '.timestamp // "?"' "$f" 2>/dev/null)
    _bdb=$(jq -r '.db_size // "?"' "$f" 2>/dev/null)
    _bfc=$(jq -r '.file_count // 0' "$f" 2>/dev/null)
    _bfn=$(basename "$f" .json)

    _list="${_list}
<b>${_count}.</b> 🆔 <code>${_bid}</code>
   📅 ${_bts}
   📦 DB: ${_bdb} | ملفات: ${_bfc}
"

    if [ "$_count" -le 5 ]; then
      _kb_buttons="${_kb_buttons}
    {\"text\": \"🔄 ${_count}. ${_bid}\", \"callback_data\": \"restore_${_bfn}\"},"
    fi
  done

  if [ "$_count" -eq 0 ]; then
    send_keyboard "📋 <b>قائمة النسخ الاحتياطية</b>

📭 لا توجد نسخ محفوظة بعد" "$MAIN_MENU"
    return
  fi

  # بناء الأزرار
  _kb="{\"inline_keyboard\": ["

  # أزرار الاستعادة
  i=0
  for f in $(ls -t "$HIST"/*.json 2>/dev/null | head -5); do
    [ -f "$f" ] || continue
    i=$((i + 1))
    _bid=$(jq -r '.id // "?"' "$f" 2>/dev/null)
    _bfn=$(basename "$f" .json)
    _kb="${_kb}[{\"text\": \"🔄 ${i}. ${_bid}\", \"callback_data\": \"restore_${_bfn}\"}],"
  done

  _kb="${_kb}[{\"text\": \"🔙 القائمة الرئيسية\", \"callback_data\": \"main\"}]]}"

  send_keyboard "📋 <b>آخر ${_count} نسخ احتياطية:</b>
${_list}
اضغط على أي نسخة لاسترجاعها:" "$_kb"
}

# ══════════════════════════════
# تحميل آخر نسخة
# ══════════════════════════════

do_download_latest() {
  _latest=$(ls -t "$HIST"/*.json 2>/dev/null | head -1)

  if [ -z "$_latest" ] || [ ! -f "$_latest" ]; then
    send_keyboard "📭 لا توجد نسخ للتحميل" "$MAIN_MENU"
    return
  fi

  _bid=$(jq -r '.id // "?"' "$_latest" 2>/dev/null)
  send_msg "📥 <b>آخر نسخة:</b> <code>$_bid</code>

الملفات محفوظة بالقناة - ابحث عن:
<code>#n8n_backup ${_bid}</code>

أو شوف الرسالة المثبّتة 📌"

  show_main
}

# ══════════════════════════════
# تنظيف النسخ القديمة
# ══════════════════════════════

do_cleanup() {
  _total=$(ls "$HIST"/*.json 2>/dev/null | wc -l || echo 0)

  if [ "$_total" -le 5 ]; then
    send_keyboard "✅ <b>لا حاجة للتنظيف</b>
عدد النسخ: $_total (أقل من 5)" "$MAIN_MENU"
    return
  fi

  # نحتفظ بآخر 5 ونحذف الباقي
  _deleted=0
  for f in $(ls -t "$HIST"/*.json 2>/dev/null | tail -n +6); do
    rm -f "$f"
    _deleted=$((_deleted + 1))
  done

  send_keyboard "🗑️ <b>تم التنظيف!</b>

🗑️ محذوف: $_deleted نسخة قديمة
✅ باقي: 5 أحدث نسخ" "$MAIN_MENU"
}

# ══════════════════════════════
# معلومات
# ══════════════════════════════

do_info() {
  _host="${N8N_HOST:-localhost}"
  _wh="${WEBHOOK_URL:-N/A}"

  send_keyboard "ℹ️ <b>معلومات النظام</b>

🌐 <b>n8n:</b> <code>https://${_host}</code>
🔗 <b>Webhook:</b> <code>${_wh}</code>
📱 <b>Chat ID:</b> <code>${TG_CHAT_ID}</code>

⏱️ <b>إعدادات الباك أب:</b>
  فحص كل: <code>${MONITOR_INTERVAL:-30}s</code>
  أقل فترة: <code>${MIN_BACKUP_INTERVAL_SEC:-30}s</code>
  إجباري كل: <code>${FORCE_BACKUP_EVERY_SEC:-900}s</code>
  حجم القطعة: <code>${CHUNK_SIZE:-18M}</code>
  Binary Data: <code>${BACKUP_BINARYDATA:-true}</code>

📝 <b>الأوامر:</b>
  /start - القائمة الرئيسية
  /status - حالة النظام
  /backup - حفظ فوري
  /list - قائمة النسخ" "$MAIN_MENU"
}

# ══════════════════════════════
# الاسترجاع
# ══════════════════════════════

do_restore_backup() {
  _fname="$1"
  _file="$HIST/${_fname}.json"

  if [ ! -f "$_file" ]; then
    send_msg "❌ النسخة غير موجودة: $_fname"
    show_main
    return
  fi

  _bid=$(jq -r '.id // "?"' "$_file" 2>/dev/null)

  # تأكيد
  _confirm_kb="{\"inline_keyboard\": [
    [{\"text\": \"✅ نعم، استرجع!\", \"callback_data\": \"confirm_restore_${_fname}\"}],
    [{\"text\": \"❌ إلغاء\", \"callback_data\": \"main\"}]
  ]}"

  send_keyboard "⚠️ <b>تأكيد الاسترجاع</b>

🆔 النسخة: <code>$_bid</code>

⚠️ هذا سيستبدل البيانات الحالية!
هل أنت متأكد؟" "$_confirm_kb"
}

do_confirm_restore() {
  _fname="$1"
  _file="$HIST/${_fname}.json"

  if [ ! -f "$_file" ]; then
    send_msg "❌ النسخة غير موجودة"
    show_main
    return
  fi

  send_msg "⏳ <b>جاري الاسترجاع...</b>
⚠️ لا تغلق أي شي"

  _bid=$(jq -r '.id // "?"' "$_file" 2>/dev/null)

  # نحمّل الملفات من تلكرام
  _tmp="/tmp/restore_$$"
  rm -rf "$_tmp"
  mkdir -p "$_tmp"

  _ok=true
  jq -r '.files[] | "\(.file_id)|\(.name)"' "$_file" 2>/dev/null | \
  while IFS='|' read -r _fid _fn; do
    [ -n "$_fid" ] || continue

    # نحصل على مسار الملف
    _path=$(curl -sS "${TG}/getFile?file_id=${_fid}" \
      | jq -r '.result.file_path // empty' 2>/dev/null)

    if [ -n "$_path" ]; then
      curl -sS -o "$_tmp/$_fn" \
        "https://api.telegram.org/file/bot${TG_BOT_TOKEN}/${_path}" || true
    fi
    sleep 1
  done

  # نوقف WAL
  if [ -f "$N8N_DIR/database.sqlite" ]; then
    sqlite3 "$N8N_DIR/database.sqlite" "PRAGMA wal_checkpoint(TRUNCATE);" 2>/dev/null || true
    rm -f "$N8N_DIR/database.sqlite" "$N8N_DIR/database.sqlite-wal" "$N8N_DIR/database.sqlite-shm"
  fi

  # نسترجع
  if ls "$_tmp"/db.sql.gz.part_* >/dev/null 2>&1; then
    cat "$_tmp"/db.sql.gz.part_* | gzip -dc | sqlite3 "$N8N_DIR/database.sqlite"
  elif [ -f "$_tmp/db.sql.gz" ]; then
    gzip -dc "$_tmp/db.sql.gz" | sqlite3 "$N8N_DIR/database.sqlite"
  fi

  if ls "$_tmp"/files.tar.gz.part_* >/dev/null 2>&1; then
    cat "$_tmp"/files.tar.gz.part_* | gzip -dc | tar -C "$N8N_DIR" -xf - 2>/dev/null || true
  elif [ -f "$_tmp/files.tar.gz" ]; then
    gzip -dc "$_tmp/files.tar.gz" | tar -C "$N8N_DIR" -xf - 2>/dev/null || true
  fi

  rm -rf "$_tmp"

  if [ -s "$N8N_DIR/database.sqlite" ]; then
    _tc=$(sqlite3 "$N8N_DIR/database.sqlite" \
      "SELECT count(*) FROM sqlite_master WHERE type='table';" 2>/dev/null || echo 0)

    send_keyboard "✅ <b>تم الاسترجاع بنجاح!</b>

🆔 النسخة: <code>$_bid</code>
📋 الجداول: <code>$_tc</code>

⚠️ <b>يجب إعادة تشغيل n8n</b>
أعد تشغيل الخدمة من Render" "$MAIN_MENU"
  else
    send_keyboard "❌ <b>فشل الاسترجاع</b>

حاول نسخة ثانية" "$MAIN_MENU"
  fi
}

# ══════════════════════════════
# حلقة الاستماع الرئيسية
# ══════════════════════════════

echo "🤖 البوت جاهز - ينتظر الأوامر..."

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
        /start|/menu)
          show_main
          ;;
        /status)
          do_status
          ;;
        /backup|/save)
          do_backup_now
          ;;
        /list|/history)
          do_list_backups
          ;;
        /info|/help)
          do_info
          ;;
      esac
    fi

    # ── Callback (أزرار) ──
    _cb_id=$(echo "$update" | jq -r '.callback_query.id // empty' 2>/dev/null)
    _cb_data=$(echo "$update" | jq -r '.callback_query.data // empty' 2>/dev/null)
    _cb_from=$(echo "$update" | jq -r '.callback_query.from.id // 0' 2>/dev/null)

    if [ -n "$_cb_id" ] && [ "$_cb_from" = "$TG_ADMIN_ID" ]; then
      answer_callback "$_cb_id" "⏳"

      case "$_cb_data" in
        main)
          show_main
          ;;
        status)
          do_status
          ;;
        backup_now)
          do_backup_now
          ;;
        list_backups)
          do_list_backups
          ;;
        download_latest)
          do_download_latest
          ;;
        cleanup)
          do_cleanup
          ;;
        info)
          do_info
          ;;
        restore_*)
          _rname=$(echo "$_cb_data" | sed 's/^restore_//')
          do_restore_backup "$_rname"
          ;;
        confirm_restore_*)
          _rname=$(echo "$_cb_data" | sed 's/^confirm_restore_//')
          do_confirm_restore "$_rname"
          ;;
      esac
    fi
  done

  # تحديث الـ offset
  _last=$(echo "$RESULTS" | jq -r '.[-1].update_id // empty' 2>/dev/null)
  [ -n "$_last" ] && OFFSET=$((_last + 1))
done
