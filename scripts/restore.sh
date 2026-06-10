#!/bin/sh
set -eu
umask 077

: "${TG_BOT_TOKEN:?}"
: "${TG_CHAT_ID:?}"

N8N_DIR="${N8N_DIR:-/home/node/.n8n}"
TG="https://api.telegram.org/bot${TG_BOT_TOKEN}"
TMP="/tmp/restore-$$"

trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT
mkdir -p "$N8N_DIR" "$TMP"

# ════════════════════════════════════════════
# فحص: هل قاعدة البيانات موجودة ومكتملة؟
# ════════════════════════════════════════════
if [ -s "$N8N_DIR/database.sqlite" ]; then
  _tc=$(sqlite3 "$N8N_DIR/database.sqlite" \
    "SELECT count(*) FROM sqlite_master WHERE type='table';" 2>/dev/null || echo 0)
  if [ "$_tc" -gt 0 ]; then
    echo "✅ DB موجودة ($_tc جدول) — لا حاجة للاسترجاع"
    exit 0
  fi
  rm -f "$N8N_DIR/database.sqlite" \
        "$N8N_DIR/database.sqlite-wal" \
        "$N8N_DIR/database.sqlite-shm" 2>/dev/null || true
fi

echo "=== 🔍 البحث عن باك أب ==="

# ════════════════════════════════════════════
# دالة: تحميل ملف من Telegram بواسطة file_id
# ════════════════════════════════════════════
dl_file() {
  _fid="$1"; _out="$2"
  _info=$(curl -sS "${TG}/getFile?file_id=${_fid}" 2>/dev/null || echo '{}')
  _path=$(echo "$_info" | jq -r '.result.file_path // empty' 2>/dev/null || true)
  [ -n "$_path" ] || { echo "    ⚠️ فشل جلب مسار الملف"; return 1; }
  curl -sS -o "$_out" \
    "https://api.telegram.org/file/bot${TG_BOT_TOKEN}/${_path}" 2>/dev/null
  [ -s "$_out" ] || { echo "    ⚠️ الملف فارغ بعد التحميل"; return 1; }
  return 0
}

# ════════════════════════════════════════════
# دالة: استرجاع DB من ملف .sql.gz
# يدعم كلا النوعين:
#   - .dump كامل (يحتوي BEGIN/COMMIT)
#   - تصدير انتقائي بـ .mode insert
# ════════════════════════════════════════════
restore_from_gz() {
  _dbgz="$1"
  _sz=$(du -sh "$_dbgz" 2>/dev/null | cut -f1)
  echo "  🔧 التحقق من الملف: $_sz ..."

  if ! gzip -t "$_dbgz" 2>/dev/null; then
    echo "  ❌ ملف gz تالف أو غير مكتمل"
    return 1
  fi

  # تنظيف أي DB قديمة
  rm -f "$N8N_DIR/database.sqlite" \
        "$N8N_DIR/database.sqlite-wal" \
        "$N8N_DIR/database.sqlite-shm" 2>/dev/null || true

  # استرجاع
  gzip -dc "$_dbgz" | sqlite3 "$N8N_DIR/database.sqlite" 2>/dev/null

  if [ ! -s "$N8N_DIR/database.sqlite" ]; then
    rm -f "$N8N_DIR/database.sqlite" 2>/dev/null || true
    echo "  ❌ فشل إنشاء قاعدة البيانات"
    return 1
  fi

  _tc=$(sqlite3 "$N8N_DIR/database.sqlite" \
    "SELECT count(*) FROM sqlite_master WHERE type='table';" 2>/dev/null || echo 0)

  if [ "$_tc" -gt 0 ]; then
    # تحقق أن جدول workflows موجود (الأهم)
    _wf=$(sqlite3 "$N8N_DIR/database.sqlite" \
      "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='workflow_entity';" \
      2>/dev/null || echo 0)
    echo "  ✅ $_tc جدول | workflow_entity: $([ "$_wf" -gt 0 ] && echo موجود || echo مفقود)"

    # تحسين الـ DB بعد الاسترجاع
    sqlite3 "$N8N_DIR/database.sqlite" \
      "PRAGMA wal_checkpoint(TRUNCATE); PRAGMA optimize;" \
      >/dev/null 2>&1 || true

    return 0
  fi

  rm -f "$N8N_DIR/database.sqlite" 2>/dev/null || true
  echo "  ❌ قاعدة البيانات فارغة (0 جداول)"
  return 1
}

# ════════════════════════════════════════════
# STEP 1: جلب الرسالة المثبّتة من getChat
# الباك أب الجديد يثبّت دائماً رسالة الملف مباشرة
# ════════════════════════════════════════════
echo ""
echo "📌 جلب الرسالة المثبّتة..."
CHAT_DATA=$(curl -sS "${TG}/getChat?chat_id=${TG_CHAT_ID}" 2>/dev/null || echo '{}')

PIN_MSG_ID=$(echo "$CHAT_DATA"  | jq -r '.result.pinned_message.message_id // empty'        2>/dev/null || true)
PIN_FID=$(echo "$CHAT_DATA"     | jq -r '.result.pinned_message.document.file_id // empty'  2>/dev/null || true)
PIN_FNAME=$(echo "$CHAT_DATA"   | jq -r '.result.pinned_message.document.file_name // empty' 2>/dev/null || true)
PIN_CAPTION=$(echo "$CHAT_DATA" | jq -r '.result.pinned_message.caption // empty'           2>/dev/null || true)

echo "  📌 message_id : ${PIN_MSG_ID:-غير موجود}"
echo "  📄 اسم الملف  : ${PIN_FNAME:-غير موجود}"
echo "  🔍 نوع الكابشن: $(echo "$PIN_CAPTION" | grep -c '#n8n_backup' || true) علامة #n8n_backup"

# ════════════════════════════════════════════
# STEP 2: تحميل الملف المثبّت مباشرة
#
# الباك أب الجديد → ملف واحد → يثبّته مباشرة
# اسم الملف: db_YYYY-MM-DD_HH-MM-SS.sql.gz
# ════════════════════════════════════════════
if [ -n "$PIN_FID" ] && [ -n "$PIN_MSG_ID" ]; then
  # تحقق أن الرسالة المثبّتة هي فعلاً باك أب n8n
  _is_backup=false
  echo "$PIN_CAPTION" | grep -q '#n8n_backup'  && _is_backup=true
  echo "$PIN_FNAME"   | grep -qE 'db.*\.sql\.gz' && _is_backup=true

  if [ "$_is_backup" = "true" ]; then
    echo ""
    echo "⬇️  تحميل الملف المثبّت: $PIN_FNAME ..."
    if dl_file "$PIN_FID" "$TMP/db_pinned.sql.gz"; then
      echo "  📦 الحجم: $(du -sh "$TMP/db_pinned.sql.gz" | cut -f1)"
      if restore_from_gz "$TMP/db_pinned.sql.gz"; then
        echo ""
        echo "🎉 تم الاسترجاع بنجاح!"
        echo "  📄 من: $PIN_FNAME"
        # استخراج التاريخ من اسم الملف
        _ts=$(echo "$PIN_FNAME" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}' | head -1 || true)
        [ -n "$_ts" ] && echo "  🕐 تاريخ الباك أب: $_ts"
        exit 0
      fi
    fi
  else
    echo "  ⚠️ الرسالة المثبّتة لا تبدو باك أب n8n — سيتم البحث في التاريخ"
  fi
fi

# ════════════════════════════════════════════
# STEP 3: فول باك — مشي للخلف من الرسالة المثبّتة
#          والبحث عن أحدث ملف sql.gz
#
# نفحص 20 رسالة للخلف من PIN_MSG_ID
# ════════════════════════════════════════════
echo ""
echo "🔄 بحث في التاريخ عن آخر باك أب..."

if [ -z "$PIN_MSG_ID" ] || ! [ "$PIN_MSG_ID" -gt 0 ] 2>/dev/null; then
  echo "  ❌ لا يوجد message_id للبدء منه"
  echo ""
  echo "📭 فشل الاسترجاع — لم يُعثر على نسخة قابلة للاسترجاع"
  exit 1
fi

_found=false
_scan_back=30   # نفحص 30 رسالة للخلف

_i=0
while [ "$_i" -le "$_scan_back" ]; do
  _mid=$(( PIN_MSG_ID - _i ))
  [ "$_mid" -le 0 ] && break

  # إعادة توجيه الرسالة لاستخراج محتواها
  _resp=$(curl -sS -X POST "${TG}/forwardMessage" \
    -d "chat_id=${TG_CHAT_ID}&from_chat_id=${TG_CHAT_ID}&message_id=${_mid}&disable_notification=true" \
    2>/dev/null || echo '{}')

  _fwd_id=$(echo "$_resp" | jq -r '.result.message_id // empty' 2>/dev/null || true)
  _fid=$(echo "$_resp"    | jq -r '.result.document.file_id   // empty' 2>/dev/null || true)
  _fname=$(echo "$_resp"  | jq -r '.result.document.file_name // empty' 2>/dev/null || true)
  _cap=$(echo "$_resp"    | jq -r '.result.caption            // empty' 2>/dev/null || true)

  # حذف الرسالة المعاد توجيهها فوراً
  if [ -n "$_fwd_id" ]; then
    curl -sS -X POST "${TG}/deleteMessage" \
      -d "chat_id=${TG_CHAT_ID}&message_id=${_fwd_id}" \
      >/dev/null 2>&1 || true
  fi

  # هل هذه رسالة باك أب؟
  _is_bkp=false
  echo "$_cap"   | grep -q '#n8n_backup'    && _is_bkp=true
  echo "$_fname" | grep -qE 'db.*\.sql\.gz' && _is_bkp=true

  if [ "$_is_bkp" = "true" ] && [ -n "$_fid" ]; then
    echo "  📄 وُجد باك أب في msg_id=$_mid : $_fname"
    if dl_file "$_fid" "$TMP/db_found.sql.gz"; then
      echo "  📦 الحجم: $(du -sh "$TMP/db_found.sql.gz" | cut -f1)"
      if restore_from_gz "$TMP/db_found.sql.gz"; then
        echo ""
        echo "🎉 تم الاسترجاع بنجاح!"
        echo "  📄 من: $_fname (msg_id=$_mid)"
        _found=true
        break
      fi
    fi
    echo "  ⚠️ هذا الباك أب لم ينجح — المتابعة..."
  fi

  _i=$(( _i + 1 ))
done

if [ "$_found" = "false" ]; then
  echo ""
  echo "📭 فشل الاسترجاع — لم يُعثر على نسخة قابلة للاسترجاع في آخر $_scan_back رسالة"
  exit 1
fi

exit 0
