#!/bin/bash
set -eu

: "${TG_BOT_TOKEN:?}"
: "${TG_CHAT_ID:?}"
: "${TG_ADMIN_ID:?}"

N8N_DIR="${N8N_DIR:-/home/node/.n8n}"
WORK="${WORK:-/backup-data}"
HIST="$WORK/history"
TG="https://api.telegram.org/bot${TG_BOT_TOKEN}"
OFFSET=0
OFFSET_FILE="$WORK/.bot_offset"

mkdir -p "$HIST"

# استعادة الـ offset المحفوظ
if [ -f "$OFFSET_FILE" ]; then
  OFFSET=$(cat "$OFFSET_FILE" 2>/dev/null || echo 0)
fi

# ══════════════════════════════
# دوال الإرسال
# ══════════════════════════════

tg_post() {
  _endpoint="$1"
  shift
  curl -sS --max-time 30 -X POST "${TG}/${_endpoint}" "$@" 2>/dev/null || true
}

send_msg() {
  _text="$1"
  tg_post "sendMessage" \
    -H "Content-Type: application/json" \
    -d "{\"chat_id\":${TG_ADMIN_ID},\"text\":$(echo "$_text" | jq -Rs .),\"parse_mode\":\"HTML\"}" \
    >/dev/null
}

send_keyboard() {
  _text="$1"
  _kb="$2"
  tg_post "sendMessage" \
    -H "Content-Type: application/json" \
    -d "{\"chat_id\":${TG_ADMIN_ID},\"text\":$(echo "$_text" | jq -Rs .),\"parse_mode\":\"HTML\",\"reply_markup\":${_kb}}" \
    >/dev/null
}

answer_callback() {
  tg_post "answerCallbackQuery" \
    -d "callback_query_id=$1" \
    -d "text=${2:-✅}" \
    >/dev/null
}

# ══════════════════════════════
# القوائم
# ══════════════════════════════

MAIN_MENU='{
  "inline_keyboard": [
    [{"text":"📊 حالة النظام","callback_data":"status"}],
    [{"text":"💾 حفظ الآن","callback_data":"backup_now"}],
    [{"text":"📋 قائمة النسخ","callback_data":"list_backups"}],
    [{"text":"📥 آخر نسخة","callback_data":"download_latest"}],
    [{"text":"🗑️ تنظيف النسخ القديمة","callback_data":"cleanup"}],
    [{"text":"ℹ️ معلومات","callback_data":"info"}]
  ]
}'

show_main() {
  send_keyboard "🤖 <b>لوحة التحكم - n8n Backup v5</b>

اختر العملية:" "$MAIN_MENU"
}

# ══════════════════════════════
# حالة النظام
# ══════════════════════════════

do_status() {
  _db="$N8N_DIR/database.sqlite"
  _db_size="—"
  _db_tables=0
  _db_time="—"
  _wal_size="—"
  _last_bkp="لا يوجد"
  _last_time="—"
  _total_bkps=0

  if [ -f "$_db" ]; then
    _db_size=$(du -h "$_db" | cut -f1)
    _db_tables=$(sqlite3 "$_db" \
      "SELECT count(*) FROM sqlite_master WHERE type='table';" 2>/dev/null || echo 0)
    _db_mtime=$(stat -c '%Y' "$_db" 2>/dev/null || echo 0)
    _db_time=$(date -d "@$_db_mtime" "+%Y-%m-%d %H:%M" 2>/dev/null || \
               date -u "+%Y-%m-%d %H:%M")
    _wal_size=$([ -f "${_db}-wal" ] && du -h "${_db}-wal" | cut -f1 || echo "0")
  fi

  if [ -f "$WORK/.backup_state" ]; then
    _last_bkp=$(grep '^ID=' "$WORK/.backup_state" | cut -d= -f2 || echo "—")
    _last_time=$(grep '^TS=' "$WORK/.backup_state" | cut -d= -f2 || echo "—")
  fi

  _total_bkps=$(ls "$HIST"/*.json 2>/dev/null | wc -l || echo 0)

  _disk_work=$(du -sh "$WORK" 2>/dev/null | cut -f1 || echo "?")
  _disk_n8n=$(du -sh "$N8N_DIR" 2>/dev/null | cut -f1 || echo "?")

  send_keyboard "📊 <b>حالة النظام</b>

🗄️ <b>قاعدة البيانات:</b>
  📦 الحجم: <code>$_db_size</code>
  📋 الجداول: <code>$_db_tables</code>
  📝 WAL: <code>$_wal_size</code>
  🕒 آخر تعديل: <code>$_db_time</code>

💾 <b>الباك أب:</b>
  📌 آخر نسخة: <code>$_last_bkp</code>
  🕒 الوقت: <code>$_last_time</code>
  📊 مجموع النسخ: <code>$_total_bkps</code>

💿 <b>المساحة:</b>
  n8n: <code>$_disk_n8n</code> | Backup: <code>$_disk_work</code>

⏰ <code>$(date -u '+%Y-%m-%d %H:%M:%S UTC')</code>" "$MAIN_MENU"
}

# ══════════════════════════════
# حفظ فوري
# ══════════════════════════════

do_backup_now() {
  send_msg "⏳ <b>جاري الحفظ الآن...</b>"

  rm -f "$WORK/.backup_state" 2>/dev/null || true

  _out=$(sh /scripts/backup.sh 2>&1 || true)

  if echo "$_out" | grep -q "اكتمل"; then
    _id=$(grep '^ID=' "$WORK/.backup_state" 2>/dev/null | cut -d= -f2 || echo "?")
    send_keyboard "✅ <b>تم الحفظ بنجاح!</b>

🆔 <code>$_id</code>
🕒 <code>$(date -u '+%Y-%m-%d %H:%M:%S UTC')</code>" "$MAIN_MENU"
  else
    _err=$(echo "$_out" | tail -5)
    send_keyboard "❌ <b>فشل الحفظ</b>

<pre>$(echo "$_err" | head -c 500)</pre>" "$MAIN_MENU"
  fi
}

# ══════════════════════════════
# قائمة النسخ
# ══════════════════════════════

do_list_backups() {
  _count=0
  _list=""
  _kb="[{\"text\":\"🔙 رجوع\",\"callback_data\":\"main\"}]"
  _restore_btns=""

  for f in $(ls -t "$HIST"/*.json 2>/dev/null | head -10); do
    [ -f "$f" ] || continue
    _count=$((_count + 1))

    _bid=$(jq -r '.id // "?"' "$f" 2>/dev/null)
    _bts=$(jq -r '.timestamp // "?"' "$f" 2>/dev/null)
    _bdb=$(jq -r '.db_size // "?"' "$f" 2>/dev/null)
    _bfc=$(jq -r '.file_count // 0' "$f" 2>/dev/null)
    _bfn=$(basename "$f" .json)

    _list="${_list}
<b>${_count}.</b> <code>${_bid}</code>
   📅 ${_bts} | 📦 ${_bdb}"

    if [ "$_count" -le 5 ]; then
      _restore_btns="${_restore_btns}[{\"text\":\"🔄 ${_count}. ${_bid}\",\"callback_data\":\"restore_${_bfn}\"}],"
    fi
  done

  if [ "$_count" -eq 0 ]; then
    send_keyboard "📋 <b>قائمة النسخ</b>

📭 لا توجد نسخ محفوظة بعد" "$MAIN_MENU"
    return
  fi

  _full_kb="{\"inline_keyboard\":[${_restore_btns}[{\"text\":\"🔙 رجوع\",\"callback_data\":\"main\"}]]}"

  send_keyboard "📋 <b>آخر ${_count} نسخ:</b>
${_list}

اضغط لاسترجاع أي نسخة:" "$_full_kb"
}

# ══════════════════════════════
# آخر نسخة
# ══════════════════════════════

do_download_latest() {
  _latest=$(ls -t "$HIST"/*.json 2>/dev/null | head -1 || true)

  if [ -z "$_latest" ] || [ ! -f "$_latest" ]; then
    send_keyboard "📭 لا توجد نسخ محفوظة حتى الآن" "$MAIN_MENU"
    return
  fi

  _bid=$(jq -r '.id // "?"' "$_latest" 2>/dev/null)
  _bts=$(jq -r '.timestamp // "?"' "$_latest" 2>/dev/null)
  _bdb=$(jq -r '.db_size // "?"' "$_latest" 2>/dev/null)
  _bfc=$(jq -r '.file_count // 0' "$_latest" 2>/dev/null)

  send_keyboard "📥 <b>آخر نسخة احتياطية:</b>

🆔 <code>$_bid</code>
📅 $_bts
📦 DB: $_bdb | ملفات: $_bfc

ابحث في القناة عن:
<code>#n8n_backup $_bid</code>

أو شوف الرسالة المثبّتة 📌" "$MAIN_MENU"
}

# ══════════════════════════════
# تنظيف
# ══════════════════════════════

do_cleanup() {
  _total=$(ls "$HIST"/*.json 2>/dev/null | wc -l || echo 0)

  if [ "$_total" -le 5 ]; then
    send_keyboard "✅ <b>لا حاجة للتنظيف</b>

عدد النسخ المحلية: <code>$_total</code> (الحد الأدنى 5)" "$MAIN_MENU"
    return
  fi

  _deleted=0
  for f in $(ls -t "$HIST"/*.json 2>/dev/null | tail -n +6); do
    rm -f "$f" && _deleted=$((_deleted + 1)) || true
  done

  send_keyboard "🗑️ <b>تم التنظيف!</b>

🗑️ محذوف: <code>$_deleted</code> نسخة قديمة
✅ باقي: <code>5</code> أحدث نسخ" "$MAIN_MENU"
}

# ══════════════════════════════
# معلومات
# ══════════════════════════════

do_info() {
  send_keyboard "ℹ️ <b>معلومات النظام</b>

🌐 <b>n8n URL:</b>
<code>${WEBHOOK_URL:-غير محدد}</code>

⏱️ <b>إعدادات الباك أب:</b>
  فحص كل: <code>${MONITOR_INTERVAL:-60}s</code>
  أقل فترة: <code>${MIN_BACKUP_INTERVAL_SEC:-120}s</code>
  إجباري كل: <code>${FORCE_BACKUP_EVERY_SEC:-1800}s</code>
  حجم القطعة: <code>${CHUNK_SIZE:-45M}</code>
  Binary Data: <code>${BACKUP_BINARYDATA:-false}</code>

📝 <b>الأوامر:</b>
  /start - القائمة الرئيسية
  /status - حالة النظام
  /backup - حفظ فوري
  /list - قائمة النسخ
  /info - هذه المعلومات

🔧 <b>النظام:</b>
  n8n: <code>$(n8n --version 2>/dev/null || echo '?')</code>
  وقت التشغيل: <code>$(date -u '+%Y-%m-%d %H:%M UTC')</code>" "$MAIN_MENU"
}

# ══════════════════════════════
# الاسترجاع
# ══════════════════════════════

do_restore_backup() {
  _fname="$1"
  _file="$HIST/${_fname}.json"

  if [ ! -f "$_file" ]; then
    send_msg "❌ النسخة غير موجودة: <code>$_fname</code>"
    show_main
    return
  fi

  _bid=$(jq -r '.id // "?"' "$_file" 2>/dev/null)
  _bts=$(jq -r '.timestamp // "?"' "$_file" 2>/dev/null)
  _bdb=$(jq -r '.db_size // "?"' "$_file" 2>/dev/null)

  _confirm_kb="{\"inline_keyboard\":[
    [{\"text\":\"✅ نعم، استرجع الآن!\",\"callback_data\":\"confirm_restore_${_fname}\"}],
    [{\"text\":\"❌ إلغاء\",\"callback_data\":\"main\"}]
  ]}"

  send_keyboard "⚠️ <b>تأكيد الاسترجاع</b>

🆔 <code>$_bid</code>
📅 $_bts
📦 DB: $_bdb

⚠️ <b>تحذير:</b> سيستبدل هذا البيانات الحالية!
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

  _bid=$(jq -r '.id // "?"' "$_file" 2>/dev/null)
  send_msg "⏳ <b>جاري الاسترجاع...</b>
🆔 <code>$_bid</code>
⚠️ لا تغلق أي شيء"

  _tmp="/tmp/restore_bot_$$"
  rm -rf "$_tmp"
  mkdir -p "$_tmp"

  # تحميل الملفات
  _ok=true
  while IFS='|' read -r _fid _fn; do
    [ -n "$_fid" ] && [ -n "$_fn" ] || continue
    _path=$(curl -sS --max-time 15 "${TG}/getFile?file_id=${_fid}" \
      | jq -r '.result.file_path // empty' 2>/dev/null || true)

    if [ -n "$_path" ]; then
      curl -sS --max-time 120 -o "$_tmp/$_fn" \
        "https://api.telegram.org/file/bot${TG_BOT_TOKEN}/${_path}" 2>/dev/null || true
    fi
    sleep 1
  done << EOF
$(jq -r '.files[] | "\(.file_id)|\(.name)"' "$_file" 2>/dev/null)
EOF

  # تطبيق الاسترجاع
  sqlite3 "$N8N_DIR/database.sqlite" \
    "PRAGMA wal_checkpoint(TRUNCATE);" 2>/dev/null || true
  rm -f "$N8N_DIR/database.sqlite" \
        "$N8N_DIR/database.sqlite-wal" \
        "$N8N_DIR/database.sqlite-shm" 2>/dev/null || true

  if ls "$_tmp"/db.sql.gz.part_* >/dev/null 2>&1; then
    cat $(ls -v "$_tmp"/db.sql.gz.part_*) | gzip -dc | \
      sqlite3 "$N8N_DIR/database.sqlite" 2>/dev/null || _ok=false
  elif [ -f "$_tmp/db.sql.gz" ]; then
    gzip -dc "$_tmp/db.sql.gz" | \
      sqlite3 "$N8N_DIR/database.sqlite" 2>/dev/null || _ok=false
  else
    _ok=false
  fi

  if ls "$_tmp"/files.tar.gz.part_* >/dev/null 2>&1; then
    cat $(ls -v "$_tmp"/files.tar.gz.part_*) | gzip -dc | \
      tar -C "$N8N_DIR" -xf - 2>/dev/null || true
  elif [ -f "$_tmp/files.tar.gz" ]; then
    gzip -dc "$_tmp/files.tar.gz" | \
      tar -C "$N8N_DIR" -xf - 2>/dev/null || true
  fi

  rm -rf "$_tmp"

  if [ "$_ok" = "true" ] && [ -s "$N8N_DIR/database.sqlite" ]; then
    _tc=$(sqlite3 "$N8N_DIR/database.sqlite" \
      "SELECT count(*) FROM sqlite_master WHERE type='table';" 2>/dev/null || echo 0)
    send_keyboard "✅ <b>تم الاسترجاع!</b>

🆔 <code>$_bid</code>
📋 الجداول: <code>$_tc</code>

⚠️ أعد تشغيل الخدمة من Render للتطبيق" "$MAIN_MENU"
  else
    send_keyboard "❌ <b>فشل الاسترجاع</b>

جرب نسخة أخرى من /list" "$MAIN_MENU"
  fi
}

# ══════════════════════════════
# حلقة الاستماع
# ══════════════════════════════

echo "🤖 البوت جاهز..."

while true; do
  UPDATES=$(curl -sS --max-time 35 \
    "${TG}/getUpdates?offset=${OFFSET}&timeout=30&allowed_updates=[\"message\",\"callback_query\"]" \
    2>/dev/null || true)

  if [ -z "$UPDATES" ]; then
    sleep 3
    continue
  fi

  _ok=$(echo "$UPDATES" | jq -r '.ok // "false"' 2>/dev/null || echo "false")
  if [ "$_ok" != "true" ]; then
    sleep 5
    continue
  fi

  _count=$(echo "$UPDATES" | jq '.result | length' 2>/dev/null || echo 0)
  [ "$_count" -gt 0 ] || continue

  # معالجة كل update
  i=0
  while [ "$i" -lt "$_count" ]; do
    update=$(echo "$UPDATES" | jq -c ".result[$i]" 2>/dev/null || true)
    [ -n "$update" ] || { i=$((i+1)); continue; }

    _uid=$(echo "$update" | jq -r '.update_id' 2>/dev/null || echo 0)
    OFFSET=$((_uid + 1))
    echo "$OFFSET" > "$OFFSET_FILE"

    # ── رسالة نصية ──
    _text=$(echo "$update" | jq -r '.message.text // empty' 2>/dev/null || true)
    _from=$(echo "$update" | jq -r '.message.from.id // 0' 2>/dev/null || echo 0)

    if [ -n "$_text" ] && [ "$_from" = "$TG_ADMIN_ID" ]; then
      case "$_text" in
        /start|/menu|/help)  show_main ;;
        /status)              do_status ;;
        /backup|/save)        do_backup_now ;;
        /list|/history)       do_list_backups ;;
        /info)                do_info ;;
      esac
    fi

    # ── Callback أزرار ──
    _cb_id=$(echo "$update" | jq -r '.callback_query.id // empty' 2>/dev/null || true)
    _cb_data=$(echo "$update" | jq -r '.callback_query.data // empty' 2>/dev/null || true)
    _cb_from=$(echo "$update" | jq -r '.callback_query.from.id // 0' 2>/dev/null || echo 0)

    if [ -n "$_cb_id" ] && [ "$_cb_from" = "$TG_ADMIN_ID" ]; then
      answer_callback "$_cb_id" "⏳"

      case "$_cb_data" in
        main)             show_main ;;
        status)           do_status ;;
        backup_now)       do_backup_now ;;
        list_backups)     do_list_backups ;;
        download_latest)  do_download_latest ;;
        cleanup)          do_cleanup ;;
        info)             do_info ;;
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

    i=$((i+1))
  done
done
