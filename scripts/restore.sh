#!/bin/sh
set -eu
umask 077

: "${TG_BOT_TOKEN:?}"
: "${TG_CHAT_ID:?}"

N8N_DIR="${N8N_DIR:-/home/node/.n8n}"
TG="https://api.telegram.org/bot${TG_BOT_TOKEN}"
TMP="/tmp/restore-$$"

trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT
mkdir -p "$N8N_DIR" "$TMP" "$TMP/parts"

# ════════════════════════════════════════════
# فحص: هل قاعدة البيانات موجودة ومكتملة؟
# ════════════════════════════════════════════
if [ -s "$N8N_DIR/database.sqlite" ]; then
  _tc=$(sqlite3 "$N8N_DIR/database.sqlite" \
    "SELECT count(*) FROM sqlite_master WHERE type='table';" 2>/dev/null || echo 0)
  if [ "$_tc" -gt 0 ]; then
    echo "✅ DB موجودة ($_tc جدول)"
    exit 0
  fi
  rm -f "$N8N_DIR/database.sqlite"
fi

echo "=== 🔍 البحث عن باك أب ==="

# ════════════════════════════════════════════
# دالة: تحميل ملف من Telegram بواسطة file_id
# ════════════════════════════════════════════
dl_file() {
  _fid="$1"; _out="$2"
  _path=$(curl -sS "${TG}/getFile?file_id=${_fid}" \
    | jq -r '.result.file_path // empty' 2>/dev/null)
  [ -n "$_path" ] || { echo "    ⚠️ فشل جلب مسار الملف"; return 1; }
  curl -sS -o "$_out" \
    "https://api.telegram.org/file/bot${TG_BOT_TOKEN}/${_path}"
  [ -s "$_out" ] || { echo "    ⚠️ الملف فارغ بعد التحميل"; return 1; }
}

# ════════════════════════════════════════════
# دالة: استرجاع قاعدة البيانات من ملف gz
# ════════════════════════════════════════════
restore_from_gz() {
  _dbgz="$1"
  echo "  🔧 التحقق من الملف: $(du -sh "$_dbgz" 2>/dev/null | cut -f1) ..."
  if ! gzip -t "$_dbgz" 2>/dev/null; then
    echo "  ❌ ملف gz تالف أو غير مكتمل"
    return 1
  fi
  rm -f "$N8N_DIR/database.sqlite"
  gzip -dc "$_dbgz" | sqlite3 "$N8N_DIR/database.sqlite" 2>/dev/null
  if [ ! -s "$N8N_DIR/database.sqlite" ]; then
    rm -f "$N8N_DIR/database.sqlite"
    echo "  ❌ فشل إنشاء قاعدة البيانات"
    return 1
  fi
  _tc=$(sqlite3 "$N8N_DIR/database.sqlite" \
    "SELECT count(*) FROM sqlite_master WHERE type='table';" 2>/dev/null || echo 0)
  if [ "$_tc" -gt 0 ]; then
    echo "  ✅ $_tc جدول — تم الاسترجاع بنجاح!"
    return 0
  fi
  rm -f "$N8N_DIR/database.sqlite"
  echo "  ❌ قاعدة البيانات فارغة (0 جداول)"
  return 1
}

# ════════════════════════════════════════════
# دالة: جلب رسالة واحدة بواسطة message_id
# (يستخدم copyMessage كـ workaround لأن
#  getMessages غير متاح في Bot API العادي)
# ════════════════════════════════════════════
get_message_doc() {
  _msg_id="$1"
  # نجلب الرسالة عبر forwardMessage إلى نفس الشات (بدون إشعار)
  # ثم نحذفها فوراً بعد استخراج file_id
  _resp=$(curl -sS -X POST "${TG}/forwardMessage" \
    -d "chat_id=${TG_CHAT_ID}&from_chat_id=${TG_CHAT_ID}&message_id=${_msg_id}&disable_notification=true" \
    2>/dev/null || echo '{}')

  _fwd_id=$(echo "$_resp" | jq -r '.result.message_id // empty' 2>/dev/null || true)
  _fid=$(echo "$_resp" | jq -r '.result.document.file_id // empty' 2>/dev/null || true)
  _fname=$(echo "$_resp" | jq -r '.result.document.file_name // empty' 2>/dev/null || true)
  _cap=$(echo "$_resp" | jq -r '.result.caption // empty' 2>/dev/null || true)

  # حذف الرسالة المعاد توجيهها
  if [ -n "$_fwd_id" ]; then
    curl -sS -X POST "${TG}/deleteMessage" \
      -d "chat_id=${TG_CHAT_ID}&message_id=${_fwd_id}" >/dev/null 2>&1 || true
  fi

  # إرجاع البيانات
  printf '%s|%s|%s' "$_fid" "$_fname" "$_cap"
}

# ════════════════════════════════════════════
# دالة: استخراج BACKUP_ID من نص
# ════════════════════════════════════════════
extract_backup_id() {
  echo "$1" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}' | head -1 || true
}

# ════════════════════════════════════════════
# STEP 1: جلب الرسالة المثبّتة (المانيفست)
# ════════════════════════════════════════════
echo ""
echo "📌 جلب الرسالة المثبّتة..."
CHAT_DATA=$(curl -sS "${TG}/getChat?chat_id=${TG_CHAT_ID}" 2>/dev/null || echo '{}')

PIN_MSG_ID=$(echo "$CHAT_DATA" | jq -r '.result.pinned_message.message_id // empty' 2>/dev/null || true)
PIN_CAPTION=$(echo "$CHAT_DATA" | jq -r '.result.pinned_message.caption // empty' 2>/dev/null || true)
PIN_FNAME=$(echo "$CHAT_DATA" | jq -r '.result.pinned_message.document.file_name // empty' 2>/dev/null || true)
PIN_FID=$(echo "$CHAT_DATA" | jq -r '.result.pinned_message.document.file_id // empty' 2>/dev/null || true)

echo "  📌 message_id: ${PIN_MSG_ID:-غير موجود}"
echo "  📄 اسم الملف: ${PIN_FNAME:-غير موجود}"

# ════════════════════════════════════════════
# STEP 2: استخراج BACKUP_ID وعدد الأجزاء
# ════════════════════════════════════════════
BACKUP_ID=$(extract_backup_id "$PIN_CAPTION")
[ -z "$BACKUP_ID" ] && BACKUP_ID=$(extract_backup_id "$PIN_FNAME")

# استخراج عدد الأجزاء من الكابشن: "أجزاء: 2" أو "2 من 2"
TOTAL_PARTS=$(echo "$PIN_CAPTION" | grep -oE 'أجزاء: ([0-9]+)' | grep -oE '[0-9]+' | head -1 || true)
[ -z "$TOTAL_PARTS" ] && \
  TOTAL_PARTS=$(echo "$PIN_CAPTION" | grep -oE '[0-9]+ من ([0-9]+)' | grep -oE '[0-9]+$' | head -1 || true)
[ -z "$TOTAL_PARTS" ] && TOTAL_PARTS=1

echo "  🆔 Backup ID: ${BACKUP_ID:-غير محدد}"
echo "  🔢 عدد الأجزاء المتوقع: $TOTAL_PARTS"

# ════════════════════════════════════════════
# STEP 3: استرجاع كل الأجزاء بالمشي للخلف من
#          message_id للرسالة المثبّتة (المانيفست)
#
# الترتيب في القناة:
#   msg_id - TOTAL_PARTS  → part_000
#   msg_id - TOTAL_PARTS+1 → part_001
#   ...
#   msg_id - 1            → آخر جزء
#   msg_id                → المانيفست (مثبّت)
# ════════════════════════════════════════════
try_restore_by_message_id() {
  _manifest_id="$1"
  _n_parts="$2"
  _bid="$3"

  echo ""
  echo "📦 جلب $_n_parts جزء ابتداءً من message_id=$(( _manifest_id - _n_parts ))"

  rm -rf "$TMP/parts"
  mkdir -p "$TMP/parts"

  _parts_ok=0
  _i=0
  while [ "$_i" -lt "$_n_parts" ]; do
    _mid=$(( _manifest_id - _n_parts + _i ))
    _part_name=$(printf 'db.sql.gz.part_%03d' "$_i")
    echo "  ⬇️  جلب part_$( printf '%03d' "$_i") من message_id=$_mid ..."

    _doc_info=$(get_message_doc "$_mid")
    _fid=$(echo "$_doc_info" | cut -d'|' -f1)
    _fname=$(echo "$_doc_info" | cut -d'|' -f2)
    _cap=$(echo "$_doc_info" | cut -d'|' -f3)

    # التحقق من BACKUP_ID إن وُجد
    if [ -n "$_bid" ]; then
      _match=false
      echo "$_cap"   | grep -qF "$_bid" && _match=true
      echo "$_fname" | grep -qF "$_bid" && _match=true
      if [ "$_match" = "false" ]; then
        echo "    ⚠️ الرسالة لا تطابق Backup ID — تخطّي"
        _i=$(( _i + 1 ))
        continue
      fi
    fi

    if [ -z "$_fid" ]; then
      echo "    ❌ لا يوجد مستند في هذه الرسالة"
      _i=$(( _i + 1 ))
      continue
    fi

    if dl_file "$_fid" "$TMP/parts/$_part_name"; then
      echo "    ✅ $(du -sh "$TMP/parts/$_part_name" | cut -f1)"
      _parts_ok=$(( _parts_ok + 1 ))
    else
      echo "    ❌ فشل تحميل الجزء"
    fi
    _i=$(( _i + 1 ))
  done

  if [ "$_parts_ok" -eq 0 ]; then
    echo "  ❌ لم يُحمَّل أي جزء"
    return 1
  fi

  echo ""
  echo "  🔗 تجميع $_parts_ok جزء..."
  rm -f "$TMP/db_assembled.sql.gz"

  ls "$TMP/parts/" | sort | while read -r _p; do
    cat "$TMP/parts/$_p"
  done > "$TMP/db_assembled.sql.gz"

  echo "  📦 الحجم المجمّع: $(du -sh "$TMP/db_assembled.sql.gz" | cut -f1)"
  restore_from_gz "$TMP/db_assembled.sql.gz"
}

# ════════════════════════════════════════════
# STEP 4: المحاولة الرئيسية — عبر message_id
# ════════════════════════════════════════════
if [ -n "$PIN_MSG_ID" ] && [ "$PIN_MSG_ID" -gt 0 ] 2>/dev/null; then
  if try_restore_by_message_id "$PIN_MSG_ID" "$TOTAL_PARTS" "$BACKUP_ID"; then
    echo ""
    echo "🎉 تم الاسترجاع بنجاح من: ${BACKUP_ID:-الرسالة المثبّتة}"
    exit 0
  fi
fi

# ════════════════════════════════════════════
# STEP 5: محاولة احتياطية — الملف الواحد من
#          الرسالة المثبّتة مباشرة (إن كان db.sql.gz)
# ════════════════════════════════════════════
if [ -n "$PIN_FID" ]; then
  echo ""
  echo "🔄 محاولة الملف المثبّت مباشرة: $PIN_FNAME"
  if dl_file "$PIN_FID" "$TMP/db_pinned.sql.gz"; then
    if restore_from_gz "$TMP/db_pinned.sql.gz"; then
      echo "🎉 تم الاسترجاع من الملف المثبّت!"
      exit 0
    fi
  fi
fi

# ════════════════════════════════════════════
# STEP 6: محاولة جلب الأجزاء بالbرسالة السابقة مباشرة
#          (بدون تحقق من BACKUP_ID) في حال فشل التطابق
# ════════════════════════════════════════════
if [ -n "$PIN_MSG_ID" ] && [ "$PIN_MSG_ID" -gt 0 ] 2>/dev/null && [ -n "$BACKUP_ID" ]; then
  echo ""
  echo "🔄 إعادة المحاولة بدون تحقق من Backup ID..."
  if try_restore_by_message_id "$PIN_MSG_ID" "$TOTAL_PARTS" ""; then
    echo "🎉 تم الاسترجاع!"
    exit 0
  fi
fi

echo ""
echo "📭 فشل الاسترجاع — لم يُعثر على نسخة قابلة للاسترجاع"
exit 1
