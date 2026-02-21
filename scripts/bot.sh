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

[ -f "$OFFSET_FILE" ] && OFFSET=$(cat "$OFFSET_FILE" 2>/dev/null || echo 0)

# ══════════════════════════════
# دوال
# ══════════════════════════════

send_msg() {
  curl -sS --max-time 30 -X POST "${TG}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "{\"chat_id\":${TG_ADMIN_ID},\"text\":$(echo "$1" | jq -Rs .),\"parse_mode\":\"HTML\"}" \
    >/dev/null 2>&1 || true
}

send_kb() {
  curl -sS --max-time 30 -X POST "${TG}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "{\"chat_id\":${TG_ADMIN_ID},\"text\":$(echo "$1" | jq -Rs .),\"parse_mode\":\"HTML\",\"reply_markup\":$2}" \
    >/dev/null 2>&1 || true
}

answer_cb() {
  curl -sS --max-time 10 -X POST "${TG}/answerCallbackQuery" \
    -d "callback_query_id=$1" -d "text=${2:-✅}" \
    >/dev/null 2>&1 || true
}

# ══════════════════════════════
# القائمة
# ══════════════════════════════

MENU='{
  "inline_keyboard":[
    [{"text":"📊 حالة النظام","callback_data":"status"}],
    [{"text":"💾 حفظ الآن","callback_data":"backup_now"}],
    [{"text":"📋 قائمة النسخ","callback_data":"list_backups"}],
    [{"text":"📥 آخر نسخة","callback_data":"download_latest"}],
    [{"text":"🗑️ تنظيف","callback_data":"cleanup"}],
    [{"text":"ℹ️ معلومات","callback_data":"info"}]
  ]
}'

show_main() {
  send_kb "🤖 <b>n8n Backup v6.0</b>
اختر:" "$MENU"
}

# ══════════════════════════════
# الحالة
# ══════════════════════════════

do_status() {
  _db="$N8N_DIR/database.sqlite"
  _ds="—"; _dt=0; _dtm="—"; _ws="0"; _tc=0
  _usr=0; _crd=0; _wf=0; _lb="—"; _lt="—"; _tb=0

  if [ -f "$_db" ]; then
    _ds=$(du -h "$_db" | cut -f1)
    _tc=$(sqlite3 "$_db" "SELECT count(*) FROM sqlite_master WHERE type='table';" 2>/dev/null || echo 0)
    _dt=$(stat -c '%Y' "$_db" 2>/dev/null || echo 0)
    _dtm=$(date -d "@$_dt" "+%Y-%m-%d %H:%M" 2>/dev/null || echo "?")
    _ws=$([ -f "${_db}-wal" ] && du -h "${_db}-wal" | cut -f1 || echo "0")
    _usr=$(sqlite3 "$_db" "SELECT count(*) FROM \"user\";" 2>/dev/null || echo 0)
    _crd=$(sqlite3 "$_db" "SELECT count(*) FROM credentials_entity;" 2>/dev/null || echo 0)
    _wf=$(sqlite3 "$_db" "SELECT count(*) FROM workflow_entity;" 2>/dev/null || echo 0)
  fi

  [ -f "$WORK/.backup_state" ] && {
    _lb=$(grep '^ID=' "$WORK/.backup_state" | cut -d= -f2 || echo "—")
    _lt=$(grep '^TS=' "$WORK/.backup_state" | cut -d= -f2 || echo "—")
  }

  _tb=$(ls "$HIST"/*.json 2>/dev/null | wc -l || echo 0)
  _dn=$(du -sh "$N8N_DIR" 2>/dev/null | cut -f1 || echo "?")
  _dw=$(du -sh "$WORK" 2>/dev/null | cut -f1 || echo "?")

  send_kb "📊 <b>حالة النظام</b>

🗄️ <b>DB:</b>
  حجم: <code>$_ds</code> | WAL: <code>$_ws</code>
  جداول: <code>$_tc</code> | تعديل: <code>$_dtm</code>

📊 <b>المحتوى:</b>
  👤 مستخدمين: <code>$_usr</code>
  🔑 credentials: <code>$_crd</code>
  ⚙️ workflows: <code>$_wf</code>

💾 <b>باك أب:</b>
  آخر: <code>$_lb</code>
  وقت: <code>$_lt</code>
  مجموع: <code>$_tb</code>

💿 n8n: <code>$_dn</code> | backup: <code>$_dw</code>
⏰ <code>$(date -u '+%Y-%m-%d %H:%M UTC')</code>" "$MENU"
}

# ══════════════════════════════
# حفظ فوري
# ══════════════════════════════

do_backup() {
  send_msg "⏳ <b>جاري الحفظ...</b>"
  rm -f "$WORK/.backup_state" 2>/dev/null || true

  _out=$(bash /scripts/backup.sh 2>&1 || true)

  if echo "$_out" | grep -q "اكتمل"; then
    _id=$(grep '^ID=' "$WORK/.backup_state" 2>/dev/null | cut -d= -f2 || echo "?")
    send_kb "✅ <b>تم الحفظ!</b>
🆔 <code>$_id</code>
🕒 <code>$(date -u '+%H:%M:%S UTC')</code>" "$MENU"
  else
    send_kb "❌ <b>فشل</b>
<pre>$(echo "$_out" | tail -3 | head -c 400)</pre>" "$MENU"
  fi
}

# ══════════════════════════════
# قائمة النسخ
# ══════════════════════════════

do_list() {
  _c=0; _list=""; _btns=""

  for f in $(ls -t "$HIST"/*.json 2>/dev/null | head -10); do
    [ -f "$f" ] || continue
    _c=$((_c + 1))
    _bid=$(jq -r '.id // "?"' "$f")
    _bts=$(jq -r '.timestamp // "?"' "$f")
    _bdb=$(jq -r '.db_size // "?"' "$f")
    _bfn=$(basename "$f" .json)

    _list="${_list}
<b>${_c}.</b> <code>${_bid}</code>
   📅 ${_bts} | 📦 ${_bdb}"

    [ "$_c" -le 5 ] && \
      _btns="${_btns}[{\"text\":\"🔄 ${_c}. ${_bid}\",\"callback_data\":\"restore_${_bfn}\"}],"
  done

  if [ "$_c" -eq 0 ]; then
    send_kb "📭 لا توجد نسخ" "$MENU"
    return
  fi

  send_kb "📋 <b>آخر ${_c} نسخ:</b>
${_list}" \
    "{\"inline_keyboard\":[${_btns}[{\"text\":\"🔙 رجوع\",\"callback_data\":\"main\"}]]}"
}

# ══════════════════════════════
# آخر نسخة
# ══════════════════════════════

do_latest() {
  _l=$(ls -t "$HIST"/*.json 2>/dev/null | head -1 || true)
  [ -n "$_l" ] && [ -f "$_l" ] || { send_kb "📭 لا توجد نسخ" "$MENU"; return; }

  _bid=$(jq -r '.id // "?"' "$_l")
  send_kb "📥 <b>آخر نسخة:</b> <code>$_bid</code>

ابحث في القناة:
<code>#n8n_backup $_bid</code>
أو 📌 الرسالة المثبّتة" "$MENU"
}

# ══════════════════════════════
# تنظيف
# ══════════════════════════════

do_cleanup() {
  _t=$(ls "$HIST"/*.json 2>/dev/null | wc -l || echo 0)
  [ "$_t" -gt 5 ] || { send_kb "✅ لا حاجة ($_t نسخ)" "$MENU"; return; }

  _d=0
  for f in $(ls -t "$HIST"/*.json | tail -n +6); do
    rm -f "$f" && _d=$((_d + 1)) || true
  done
  send_kb "🗑️ حذف: $_d | باقي: 5" "$MENU"
}

# ══════════════════════════════
# معلومات
# ══════════════════════════════

do_info() {
  send_kb "ℹ️ <b>معلومات</b>

🌐 <code>${WEBHOOK_URL:-N/A}</code>
⏱️ فحص: <code>${MONITOR_INTERVAL:-60}s</code>
📦 إجباري: <code>${FORCE_BACKUP_EVERY_SEC:-1800}s</code>
✂️ chunk: <code>${CHUNK_SIZE:-45M}</code>
🔐 encKey: <code>${N8N_ENCRYPTION_KEY:+SET}${N8N_ENCRYPTION_KEY:-NOT}</code>

/start /status /backup /list /info" "$MENU"
}

# ══════════════════════════════
# استرجاع
# ══════════════════════════════

do_restore() {
  _fn="$1"
  _f="$HIST/${_fn}.json"
  [ -f "$_f" ] || { send_msg "❌ غير موجودة"; show_main; return; }

  _bid=$(jq -r '.id // "?"' "$_f")
  send_kb "⚠️ <b>استرجاع:</b> <code>$_bid</code>

سيستبدل البيانات الحالية!" \
    "{\"inline_keyboard\":[[{\"text\":\"✅ نعم\",\"callback_data\":\"confirm_${_fn}\"}],[{\"text\":\"❌ لا\",\"callback_data\":\"main\"}]]}"
}

do_confirm() {
  _fn="$1"
  _f="$HIST/${_fn}.json"
  [ -f "$_f" ] || { send_msg "❌ غير موجودة"; show_main; return; }

  _bid=$(jq -r '.id // "?"' "$_f")
  send_msg "⏳ <b>استرجاع $_bid...</b>"

  # حذف DB الحالية
  rm -f "$N8N_DIR/database.sqlite" \
        "$N8N_DIR/database.sqlite-wal" \
        "$N8N_DIR/database.sqlite-shm" 2>/dev/null || true

  if bash /scripts/restore.sh 2>&1 | grep -q "اكتمل"; then
    send_kb "✅ <b>تم!</b>
⚠️ أعد تشغيل Render" "$MENU"
  else
    send_kb "❌ <b>فشل</b>" "$MENU"
  fi
}

# ══════════════════════════════
# الحلقة الرئيسية
# ══════════════════════════════

echo "🤖 البوت جاهز..."

while true; do
  UPDATES=$(curl -sS --max-time 35 \
    "${TG}/getUpdates?offset=${OFFSET}&timeout=30&allowed_updates=[\"message\",\"callback_query\"]" \
    2>/dev/null || true)

  [ -n "$UPDATES" ] || { sleep 3; continue; }

  _ok=$(echo "$UPDATES" | jq -r '.ok // "false"' 2>/dev/null || echo "false")
  [ "$_ok" = "true" ] || { sleep 5; continue; }

  _cnt=$(echo "$UPDATES" | jq '.result | length' 2>/dev/null || echo 0)
  [ "$_cnt" -gt 0 ] || continue

  _i=0
  while [ "$_i" -lt "$_cnt" ]; do
    _u=$(echo "$UPDATES" | jq -c ".result[$_i]" 2>/dev/null || true)
    [ -n "$_u" ] || { _i=$((_i+1)); continue; }

    _uid=$(echo "$_u" | jq -r '.update_id' 2>/dev/null || echo 0)
    OFFSET=$((_uid + 1))
    echo "$OFFSET" > "$OFFSET_FILE"

    # رسالة
    _text=$(echo "$_u" | jq -r '.message.text // empty' 2>/dev/null || true)
    _from=$(echo "$_u" | jq -r '.message.from.id // 0' 2>/dev/null || echo 0)

    if [ -n "$_text" ] && [ "$_from" = "$TG_ADMIN_ID" ]; then
      case "$_text" in
        /start|/menu) show_main ;;
        /status)      do_status ;;
        /backup|/save) do_backup ;;
        /list)        do_list ;;
        /info|/help)  do_info ;;
      esac
    fi

    # أزرار
    _cbid=$(echo "$_u" | jq -r '.callback_query.id // empty' 2>/dev/null || true)
    _cbd=$(echo "$_u" | jq -r '.callback_query.data // empty' 2>/dev/null || true)
    _cbf=$(echo "$_u" | jq -r '.callback_query.from.id // 0' 2>/dev/null || echo 0)

    if [ -n "$_cbid" ] && [ "$_cbf" = "$TG_ADMIN_ID" ]; then
      answer_cb "$_cbid"

      case "$_cbd" in
        main)            show_main ;;
        status)          do_status ;;
        backup_now)      do_backup ;;
        list_backups)    do_list ;;
        download_latest) do_latest ;;
        cleanup)         do_cleanup ;;
        info)            do_info ;;
        restore_*)       do_restore "${_cbd#restore_}" ;;
        confirm_*)       do_confirm "${_cbd#confirm_}" ;;
      esac
    fi

    _i=$((_i+1))
  done
done
