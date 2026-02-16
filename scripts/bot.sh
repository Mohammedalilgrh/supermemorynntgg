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
# قراءة المانيفست (القديم والجديد)
# ══════════════════════════════

# يقرأ .id أو .id
manifest_id() { jq -r '.id // "?"' "$1" 2>/dev/null; }

# يقرأ .timestamp (جديد) أو .ts (قديم)
manifest_ts() { jq -r '(.timestamp // .ts) // "?"' "$1" 2>/dev/null; }

# يقرأ .db_size (جديد) أو .db (قديم)
manifest_db() { jq -r '(.db_size // .db) // "?"' "$1" 2>/dev/null; }

# يقرأ .file_count (جديد) أو .fc (قديم)
manifest_fc() { jq -r '(.file_count // .fc) // 0' "$1" 2>/dev/null; }

# يقرأ الملفات بالصيغتين
manifest_files() {
  _mf="$1"
  _has_file_id=$(jq -r '.files[0].file_id // empty' "$_mf" 2>/dev/null)
  if [ -n "$_has_file_id" ]; then
    jq -r '.files[] | "\(.file_id)|\(.name)|\(.message_id // 0)"' "$_mf" 2>/dev/null
  else
    jq -r '.files[] | "\(.f // "")|\(.n // "")|\(.m // 0)"' "$_mf" 2>/dev/null
  fi
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

  if [ -f "$_db" ]; then
    _db_size=$(du -h "$_db" 2>/dev/null | cut -f1)
    _db_tables=$(sqlite3 "$_db" "SELECT count(*) FROM sqlite_master WHERE type='table';" 2>/dev/null || echo 0)
    _ts=$(stat -c '%Y' "$_db" 2>/dev/null || echo 0)
    _db_time=$(date -d "@$_ts" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "—")
  fi

  [ -f "$_db-wal" ] && _wal_size=$(du -h "$_db-wal" 2>/dev/null | cut -f1)

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

⏰ <code>$(date -u '+%Y-%m-%d %H:%M:%S UTC')</code>" "$MAIN_MENU"
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

  _kb="{\"inline_keyboard\": ["

  for f in $(ls -t "$HIST"/*.json 2>/dev/null | head -10); do
    [ -f "$f" ] || continue
    _count=$((_count + 1))

    _bid=$(manifest_id "$f")
    _bts=$(manifest_ts "$f")
    _bdb=$(manifest_db "$f")
    _bfc=$(manifest_fc "$f")
    _bfn=$(basename "$f" .json)

    _list="${_list}
<b>${_count}.</b> 🆔 <code>${_bid}</code>
   📅 ${_bts}
   📦 DB: ${_bdb} | ملفات: ${_bfc}
"

    if [ "$_count" -le 5 ]; then
      _kb="${_kb}[{\"text\": \"🔄 ${_count}. ${_bid}\", \"callback_data\": \"restore_${_bfn}\"}],"
    fi
  done

  _kb="${_kb}[{\"text\": \"🔙 القائمة الرئيسية\", \"callback_data\": \"main\"}]]}"

  if [ "$_count" -eq 0 ]; then
    send_keyboard "📋 <b>لا توجد نسخ</b>" "$MAIN_MENU"
  else
    send_keyboard "📋 <b>آخر ${_count} نسخ احتياطية:</b>
${_list}
اضغط على أي نسخة لاسترجاعها:" "$_kb"
  fi
}

# ══════════════════════════════
# تحميل آخر نسخة
# ══════════════════════════════

do_download_latest() {
  _latest=$(ls -t "$HIST"/*.json 2>/dev/null | head -1)

  if [ -z "$_latest" ] || [ ! -f "$_latest" ]; then
    send_keyboard "📭 لا توجد نسخ" "$MAIN_MENU"
    return
  fi

  _bid=$(manifest_id "$_latest")
  send_msg "📥 <b>آخر نسخة:</b> <code>$_bid</code>

ابحث بالقناة عن:
<code>#n8n_backup ${_bid}</code>

أو شوف الرسالة المثبّتة 📌"
  show_main
}

# ══════════════════════════════
# تنظيف
# ══════════════════════════════

do_cleanup() {
  _total=$(ls "$HIST"/*.json 2>/dev/null | wc -l || echo 0)

  if [ "$_total" -le 5 ]; then
    send_keyboard "✅ <b>لا حاجة</b> ($_total نسخ فقط)" "$MAIN_MENU"
    return
  fi

  _deleted=0
  for f in $(ls -t "$HIST"/*.json 2>/dev/null | tail -n +6); do
    rm -f "$f"
    _deleted=$((_deleted + 1))
  done

  send_keyboard "🗑️ <b>تم!</b> حذف $_deleted نسخة قديمة" "$MAIN_MENU"
}

# ══════════════════════════════
# معلومات
# ══════════════════════════════

do_info() {
  send_keyboard "ℹ️ <b>معلومات النظام</b>

🌐 <code>https://${N8N_HOST:-localhost}</code>
📱 Chat: <code>${TG_CHAT_ID}</code>

⏱️ <b>إعدادات:</b>
  فحص: <code>${MONITOR_INTERVAL:-30}s</code>
  إجباري: <code>${FORCE_BACKUP_EVERY_SEC:-900}s</code>
  قطعة: <code>${CHUNK_SIZE_BYTES:-19000000}</code>
  Binary: <code>${BACKUP_BINARYDATA:-true}</code>

📝 <b>الأوامر:</b>
/start /status /backup /list /info" "$MAIN_MENU"
}

# ══════════════════════════════
# استرجاع
# ══════════════════════════════

do_restore_backup() {
  _fname="$1"
  _file="$HIST/${_fname}.json"

  if [ ! -f "$_file" ]; then
    send_msg "❌ النسخة غير موجودة"
    show_main
    return
  fi

  _bid=$(manifest_id "$_file")

  _confirm_kb="{\"inline_keyboard\": [
    [{\"text\": \"✅ نعم، استرجع!\", \"callback_data\": \"confirm_restore_${_fname}\"}],
    [{\"text\": \"❌ إلغاء\", \"callback_data\": \"main\"}]
  ]}"

  send_keyboard "⚠️ <b>تأكيد الاسترجاع</b>

🆔 النسخة: <code>$_bid</code>

⚠️ هذا سيستبدل البيانات الحالية!
هل أنت متأكد؟" "$_confirm_kb"
}

# ══════════════════════════════
# تحميل ذكي (يدعم تغيير البوت)
# ══════════════════════════════

download_smart() {
  _fid="$1"
  _mid="$2"
  _output="$3"

  # محاولة 1: file_id
  if [ -n "$_fid" ] && [ "$_fid" != "null" ]; then
    _path=$(curl -sS "${TG}/getFile?file_id=${_fid}" 2>/dev/null \
      | jq -r '.result.file_path // empty' 2>/dev/null)
    if [ -n "$_path" ]; then
      curl -sS -o "$_output" \
        "https://api.telegram.org/file/bot${TG_BOT_TOKEN}/${_path}" 2>/dev/null
      [ -s "$_output" ] && return 0
    fi
  fi

  # محاولة 2: forward بـ message_id
  if [ -n "$_mid" ] && [ "$_mid" != "null" ] && [ "$_mid" != "0" ]; then
    _fwd=$(curl -sS -X POST "${TG}/forwardMessage" \
      -d "chat_id=${TG_CHAT_ID}" \
      -d "from_chat_id=${TG_CHAT_ID}" \
      -d "message_id=${_mid}" 2>/dev/null || true)

    _new_fid=$(echo "$_fwd" | jq -r '.result.document.file_id // empty' 2>/dev/null)
    _fwd_mid=$(echo "$_fwd" | jq -r '.result.message_id // empty' 2>/dev/null)

    [ -n "$_fwd_mid" ] && curl -sS -X POST "${TG}/deleteMessage" \
      -d "chat_id=${TG_CHAT_ID}" \
      -d "message_id=${_fwd_mid}" >/dev/null 2>&1 || true

    if [ -n "$_new_fid" ]; then
      _path2=$(curl -sS "${TG}/getFile?file_id=${_new_fid}" 2>/dev/null \
        | jq -r '.result.file_path // empty' 2>/dev/null)
      if [ -n "$_path2" ]; then
        curl -sS -o "$_output" \
          "https://api.telegram.org/file/bot${TG_BOT_TOKEN}/${_path2}" 2>/dev/null
        [ -s "$_output" ] && return 0
      fi
    fi
  fi

  return 1
}

# ══════════════════════════════
# تنفيذ الاسترجاع
# ══════════════════════════════

do_confirm_restore() {
  _fname="$1"
  _file="$HIST/${_fname}.json"

  if [ ! -f "$_file" ]; then
    send_msg "❌ النسخة غير موجودة"
    show_main
    return
  fi

  send_msg "⏳ <b>جاري الاسترجاع...</b>"

  _bid=$(manifest_id "$_file")
  _tmp="/tmp/restore_bot_$$"
  rm -rf "$_tmp"
  mkdir -p "$_tmp"

  # تحميل الملفات
  _fail=""
  manifest_files "$_file" | \
  while IFS='|' read -r _fid _fn _mid; do
    [ -n "$_fid" ] && [ "$_fid" != "" ] || continue
    [ -n "$_fn" ] && [ "$_fn" != "" ] || continue

    _retry=0
    _ok=""
    while [ "$_retry" -lt 3 ]; do
      if download_smart "$_fid" "$_mid" "$_tmp/$_fn"; then
        _ok="y"
        break
      fi
      _retry=$((_retry + 1))
      sleep 2
    done

    [ -n "$_ok" ] || echo "F" > "$_tmp/.fail"
    sleep 1
  done

  if [ -f "$_tmp/.fail" ]; then
    send_keyboard "❌ <b>فشل التحميل</b>" "$MAIN_MENU"
    rm -rf "$_tmp"
    return
  fi

  # حذف القديم
  sqlite3 "$N8N_DIR/database.sqlite" "PRAGMA wal_checkpoint(TRUNCATE);" 2>/dev/null || true
  rm -f "$N8N_DIR/database.sqlite" "$N8N_DIR/database.sqlite-wal" "$N8N_DIR/database.sqlite-shm"

  # استرجاع DB (يدعم الاسمين)
  if ls "$_tmp"/db.sql.gz.part_* >/dev/null 2>&1; then
    cat "$_tmp"/db.sql.gz.part_* | gzip -dc | sqlite3 "$N8N_DIR/database.sqlite"
  elif [ -f "$_tmp/db.sql.gz" ]; then
    gzip -dc "$_tmp/db.sql.gz" | sqlite3 "$N8N_DIR/database.sqlite"
  elif ls "$_tmp"/d.gz.p* >/dev/null 2>&1; then
    cat "$_tmp"/d.gz.p* | gzip -dc | sqlite3 "$N8N_DIR/database.sqlite"
  elif [ -f "$_tmp/d.gz" ]; then
    gzip -dc "$_tmp/d.gz" | sqlite3 "$N8N_DIR/database.sqlite"
  fi

  # استرجاع ملفات (يدعم الاسمين)
  if ls "$_tmp"/files.tar.gz.part_* >/dev/null 2>&1; then
    cat "$_tmp"/files.tar.gz.part_* | gzip -dc | tar -C "$N8N_DIR" -xf - 2>/dev/null || true
  elif [ -f "$_tmp/files.tar.gz" ]; then
    gzip -dc "$_tmp/files.tar.gz" | tar -C "$N8N_DIR" -xf - 2>/dev/null || true
  elif ls "$_tmp"/f.gz.p* >/dev/null 2>&1; then
    cat "$_tmp"/f.gz.p* | gzip -dc | tar -C "$N8N_DIR" -xf - 2>/dev/null || true
  elif [ -f "$_tmp/f.gz" ]; then
    gzip -dc "$_tmp/f.gz" | tar -C "$N8N_DIR" -xf - 2>/dev/null || true
  fi

  rm -rf "$_tmp"

  if [ -s "$N8N_DIR/database.sqlite" ]; then
    _tc=$(sqlite3 "$N8N_DIR/database.sqlite" \
      "SELECT count(*) FROM sqlite_master WHERE type='table';" 2>/dev/null || echo 0)
    send_keyboard "✅ <b>تم الاسترجاع!</b>

🆔 <code>$_bid</code>
📋 جداول: <code>$_tc</code>

⚠️ أعد تشغيل الخدمة من Render" "$MAIN_MENU"
  else
    send_keyboard "❌ <b>فشل الاسترجاع</b>" "$MAIN_MENU"
  fi
}

# ══════════════════════════════
# حلقة الاستماع
# ══════════════════════════════

echo "🤖 البوت جاهز..."

while true; do
  UPDATES=$(curl -sS "${TG}/getUpdates?offset=${OFFSET}&timeout=30" 2>/dev/null || true)

  [ -n "$UPDATES" ] || { sleep 5; continue; }
  [ "$(echo "$UPDATES" | jq -r '.ok // "false"')" = "true" ] || { sleep 5; continue; }

  echo "$UPDATES" | jq -c '.result[]' 2>/dev/null | while read -r update; do
    _uid=$(echo "$update" | jq -r '.update_id')
    OFFSET=$((_uid + 1))

    # رسالة نصية
    _text=$(echo "$update" | jq -r '.message.text // empty' 2>/dev/null)
    _from=$(echo "$update" | jq -r '.message.from.id // 0' 2>/dev/null)

    if [ -n "$_text" ] && [ "$_from" = "$TG_ADMIN_ID" ]; then
      case "$_text" in
        /start|/menu) show_main ;;
        /status) do_status ;;
        /backup|/save) do_backup_now ;;
        /list|/history) do_list_backups ;;
        /info|/help) do_info ;;
      esac
    fi

    # أزرار
    _cb_id=$(echo "$update" | jq -r '.callback_query.id // empty' 2>/dev/null)
    _cb_data=$(echo "$update" | jq -r '.callback_query.data // empty' 2>/dev/null)
    _cb_from=$(echo "$update" | jq -r '.callback_query.from.id // 0' 2>/dev/null)

    if [ -n "$_cb_id" ] && [ "$_cb_from" = "$TG_ADMIN_ID" ]; then
      answer_callback "$_cb_id" "⏳"

      case "$_cb_data" in
        main) show_main ;;
        status) do_status ;;
        backup_now) do_backup_now ;;
        list_backups) do_list_backups ;;
        download_latest) do_download_latest ;;
        cleanup) do_cleanup ;;
        info) do_info ;;
        restore_*) do_restore_backup "$(echo "$_cb_data" | sed 's/^restore_//')" ;;
        confirm_restore_*) do_confirm_restore "$(echo "$_cb_data" | sed 's/^confirm_restore_//')" ;;
      esac
    fi
  done

  _last=$(echo "$UPDATES" | jq -r '.result[-1].update_id // empty' 2>/dev/null)
  [ -n "$_last" ] && OFFSET=$((_last + 1))
done
