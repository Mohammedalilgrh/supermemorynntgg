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
# دالة: جلب الرسائل من Telegram (getUpdates)
# تجرب offset مختلفة للحصول على أكبر تغطية
# ════════════════════════════════════════════
fetch_all_updates() {
  _combined="$TMP/all_updates.json"
  echo "[]" > "$_combined"

  for _offset in -100 -200 -300 -400 -500; do
    _batch=$(curl -sS \
      "${TG}/getUpdates?offset=${_offset}&limit=100&allowed_updates=%5B%22channel_post%22%2C%22message%22%5D" \
      2>/dev/null || echo '{"result":[]}')
    # دمج النتائج
    _combined_data=$(jq -s '.[0] + .[1]' "$_combined" \
      <(echo "$_batch" | jq '.result // []') 2>/dev/null || echo "[]")
    echo "$_combined_data" > "$_combined"
  done

  cat "$_combined"
}

# ════════════════════════════════════════════
# دالة: استخراج file_id واسم الملف من الرسائل
# تدعم channel_post و message
# ════════════════════════════════════════════
extract_docs_from_updates() {
  _updates="$1"
  # استخراج: file_id|file_name|caption|date
  jq -r '
    .[] |
    (
      (.channel_post // .message) // empty
    ) |
    select(.document != null) |
    [
      (.document.file_id // ""),
      (.document.file_name // ""),
      (.caption // ""),
      (.date | tostring)
    ] | join("|")
  ' "$_updates" 2>/dev/null || true
}

# ════════════════════════════════════════════
# STEP 1: جلب جميع الرسائل
# ════════════════════════════════════════════
echo "📥 جلب الرسائل من Telegram..."
UPDATES_FILE="$TMP/updates.json"
fetch_all_updates > "$UPDATES_FILE"
_total=$(jq 'length' "$UPDATES_FILE" 2>/dev/null || echo 0)
echo "  📊 إجمالي التحديثات: $_total"

# ════════════════════════════════════════════
# STEP 2: فحص الرسالة المثبّتة
# ════════════════════════════════════════════
echo ""
echo "📌 فحص الرسالة المثبّتة..."
PINNED_DATA=$(curl -sS "${TG}/getChat?chat_id=${TG_CHAT_ID}" 2>/dev/null || echo '{}')
_pin_fname=$(echo "$PINNED_DATA"   | jq -r '.result.pinned_message.document.file_name // empty' 2>/dev/null || true)
_pin_caption=$(echo "$PINNED_DATA" | jq -r '.result.pinned_message.caption // empty'             2>/dev/null || true)
_pin_fid=$(echo "$PINNED_DATA"     | jq -r '.result.pinned_message.document.file_id // empty'    2>/dev/null || true)

echo "  📌 اسم الملف المثبّت: ${_pin_fname:-لا يوجد}"

# ════════════════════════════════════════════
# دالة: استخراج BACKUP_ID من نص (كابشن أو اسم ملف)
# الصيغة: YYYY-MM-DD_HH-MM-SS
# ════════════════════════════════════════════
extract_backup_id() {
  echo "$1" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}' | head -1 || true
}

# ════════════════════════════════════════════
# STEP 3: تحديد أحدث BACKUP_ID من كل المصادر
# ════════════════════════════════════════════
echo ""
echo "🔍 تحديد أحدث Backup ID..."

# اجمع كل الـ IDs من: الرسالة المثبّتة + جميع الرسائل
ALL_IDS=""

# من الرسالة المثبّتة
_id=$(extract_backup_id "$_pin_caption")
[ -z "$_id" ] && _id=$(extract_backup_id "$_pin_fname")
[ -n "$_id" ] && ALL_IDS="$ALL_IDS
$_id"

# من جميع الرسائل
DOCS_LIST="$TMP/docs_list.txt"
extract_docs_from_updates "$UPDATES_FILE" > "$DOCS_LIST"

while IFS='|' read -r _fid _fname _cap _date; do
  [ -z "$_fid" ] && continue
  _id=$(extract_backup_id "$_cap")
  [ -z "$_id" ] && _id=$(extract_backup_id "$_fname")
  [ -n "$_id" ] && ALL_IDS="$ALL_IDS
$_id"
done < "$DOCS_LIST"

# رتّب وخذ الأحدث (ترتيب أبجدي = ترتيب زمني لهذا الصيغة)
LATEST_BACKUP_ID=$(echo "$ALL_IDS" | grep -v '^$' | sort -r | head -1 || true)

echo "  🆔 أحدث Backup ID: ${LATEST_BACKUP_ID:-غير موجود}"

# ════════════════════════════════════════════
# STEP 4: ابحث عن جميع الأجزاء بنفس الـ BACKUP_ID
# ════════════════════════════════════════════
try_restore_parts() {
  _bid="$1"
  echo ""
  echo "📦 البحث عن أجزاء: $_bid"

  rm -rf "$TMP/parts"
  mkdir -p "$TMP/parts"

  # جمع كل الملفات المرتبطة بهذا الـ ID (أجزاء + ملف واحد)
  PARTS_FOUND=0
  SINGLE_FID=""
  SINGLE_FNAME=""

  while IFS='|' read -r _fid _fname _cap _date; do
    [ -z "$_fid" ] && continue

    # تحقق إذا هذا الملف مرتبط بالـ backup ID
    _match=false
    echo "$_cap"   | grep -qF "$_bid" && _match=true
    echo "$_fname" | grep -qF "$_bid" && _match=true

    [ "$_match" = "false" ] && continue

    echo "  🔗 ملف مرتبط: $_fname"

    # ملف أجزاء: db.sql.gz.part_000 أو db.sql.gz.part_001 إلخ
    if echo "$_fname" | grep -qE '\.part_[0-9]+$'; then
      echo "    📥 تحميل جزء: $_fname"
      if dl_file "$_fid" "$TMP/parts/$_fname"; then
        echo "    ✅ تم تحميل: $_fname ($(du -sh "$TMP/parts/$_fname" | cut -f1))"
        PARTS_FOUND=$((PARTS_FOUND + 1))
      else
        echo "    ❌ فشل تحميل: $_fname"
      fi
    # ملف واحد: db.sql.gz بدون part
    elif echo "$_fname" | grep -qE '\.sql\.gz$'; then
      SINGLE_FID="$_fid"
      SINGLE_FNAME="$_fname"
    fi
  done < "$DOCS_LIST"

  # أضف الرسالة المثبّتة إن كانت مرتبطة
  if [ -n "$_pin_fid" ]; then
    _pmatch=false
    echo "$_pin_caption" | grep -qF "$_bid" && _pmatch=true
    echo "$_pin_fname"   | grep -qF "$_bid" && _pmatch=true

    if [ "$_pmatch" = "true" ]; then
      if echo "$_pin_fname" | grep -qE '\.part_[0-9]+$'; then
        echo "  📌 تحميل جزء مثبّت: $_pin_fname"
        dl_file "$_pin_fid" "$TMP/parts/$_pin_fname" && \
          PARTS_FOUND=$((PARTS_FOUND + 1)) || true
      elif echo "$_pin_fname" | grep -qE '\.sql\.gz$'; then
        SINGLE_FID="$_pin_fid"
        SINGLE_FNAME="$_pin_fname"
      fi
    fi
  fi

  # ─── محاولة الأجزاء ───
  if [ "$PARTS_FOUND" -gt 0 ]; then
    echo ""
    echo "  🔗 تجميع $PARTS_FOUND جزء..."

    # رتّب الأجزاء بدقة حسب الرقم (part_000 → part_001 → ...)
    _sorted_parts=$(ls "$TMP/parts/" 2>/dev/null | grep -E '\.part_[0-9]+$' | \
      sort -t_ -k2 -n 2>/dev/null || \
      ls "$TMP/parts/" 2>/dev/null | grep -E '\.part_[0-9]+$' | sort)

    if [ -z "$_sorted_parts" ]; then
      echo "  ⚠️ لا توجد أجزاء في المجلد"
    else
      echo "  📋 الترتيب:"
      echo "$_sorted_parts" | while read -r _p; do
        echo "    - $_p ($(du -sh "$TMP/parts/$_p" 2>/dev/null | cut -f1))"
      done

      # دمج الأجزاء
      rm -f "$TMP/db_assembled.sql.gz"
      echo "$_sorted_parts" | while read -r _p; do
        cat "$TMP/parts/$_p"
      done > "$TMP/db_assembled.sql.gz"

      _assembled_size=$(du -sh "$TMP/db_assembled.sql.gz" 2>/dev/null | cut -f1)
      echo "  📦 حجم الملف المجمّع: $_assembled_size"

      if restore_from_gz "$TMP/db_assembled.sql.gz"; then
        return 0
      fi
    fi
  fi

  # ─── محاولة الملف الواحد ───
  if [ -n "$SINGLE_FID" ]; then
    echo ""
    echo "  📄 محاولة الملف الواحد: $SINGLE_FNAME"
    if dl_file "$SINGLE_FID" "$TMP/db_single.sql.gz"; then
      if restore_from_gz "$TMP/db_single.sql.gz"; then
        return 0
      fi
    fi
  fi

  return 1
}

# ════════════════════════════════════════════
# STEP 5: جرب أحدث backup ID أولاً
# ════════════════════════════════════════════
if [ -n "$LATEST_BACKUP_ID" ]; then
  if try_restore_parts "$LATEST_BACKUP_ID"; then
    echo ""
    echo "🎉 تم الاسترجاع بنجاح من: $LATEST_BACKUP_ID"
    exit 0
  fi
fi

# ════════════════════════════════════════════
# STEP 6: جرب باقي الـ IDs (من الأحدث للأقدم)
# ════════════════════════════════════════════
OTHER_IDS=$(echo "$ALL_IDS" | grep -v '^$' | sort -r -u | grep -v "^${LATEST_BACKUP_ID}$" || true)

if [ -n "$OTHER_IDS" ]; then
  echo ""
  echo "🔄 تجربة IDs احتياطية..."
  echo "$OTHER_IDS" | while read -r _bid; do
    [ -z "$_bid" ] && continue
    echo "  ⏩ تجربة: $_bid"
    if try_restore_parts "$_bid"; then
      echo ""
      echo "🎉 تم الاسترجاع بنجاح من: $_bid"
      exit 0
    fi
  done
fi

# ════════════════════════════════════════════
# STEP 7: بحث شامل أخير — أي ملف db.sql.gz بدون ID
# ════════════════════════════════════════════
echo ""
echo "🔍 بحث شامل أخير — أي ملف db.sql.gz..."

_fallback_fid=""
_fallback_date=0

while IFS='|' read -r _fid _fname _cap _date; do
  [ -z "$_fid" ] && continue
  if echo "$_fname" | grep -qE '(db\.sql\.gz|n8n.*backup)'; then
    if [ "$_date" -gt "$_fallback_date" ] 2>/dev/null; then
      _fallback_fid="$_fid"
      _fallback_date="$_date"
    fi
  fi
done < "$DOCS_LIST"

if [ -n "$_fallback_fid" ]; then
  echo "  📋 وجدنا ملف بتاريخ: $_fallback_date"
  if dl_file "$_fallback_fid" "$TMP/db_fallback.sql.gz"; then
    if restore_from_gz "$TMP/db_fallback.sql.gz"; then
      echo "🎉 تم الاسترجاع من البحث الشامل!"
      exit 0
    fi
  fi
fi

echo ""
echo "📭 فشل الاسترجاع — لم يُعثر على نسخة قابلة للاسترجاع"
exit 1
