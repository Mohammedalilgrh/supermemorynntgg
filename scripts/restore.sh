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

dl_file() {
  _fid="$1"; _out="$2"
  _path=$(curl -sS "${TG}/getFile?file_id=${_fid}" \
    | jq -r '.result.file_path // empty' 2>/dev/null)
  [ -n "$_path" ] || return 1
  curl -sS -o "$_out" \
    "https://api.telegram.org/file/bot${TG_BOT_TOKEN}/${_path}"
  [ -s "$_out" ]
}

restore_from_gz() {
  _dbgz="$1"
  if ! gzip -t "$_dbgz" 2>/dev/null; then
    echo "  ❌ ملف تالف"
    return 1
  fi
  gzip -dc "$_dbgz" | sqlite3 "$N8N_DIR/database.sqlite" 2>/dev/null
  if [ ! -s "$N8N_DIR/database.sqlite" ]; then
    rm -f "$N8N_DIR/database.sqlite"
    return 1
  fi
  _tc=$(sqlite3 "$N8N_DIR/database.sqlite" \
    "SELECT count(*) FROM sqlite_master WHERE type='table';" 2>/dev/null || echo 0)
  if [ "$_tc" -gt 0 ]; then
    echo "  ✅ $_tc جدول — تم الاسترجاع!"
    return 0
  fi
  rm -f "$N8N_DIR/database.sqlite"
  return 1
}

# ════════════════════════════════════════════
# الخطوة 1: جلب كل الرسائل مرة وحدة (300 رسالة)
# ════════════════════════════════════════════
echo "📥 جلب آخر 300 رسالة..."
ALL_UPDATES=$(curl -sS "${TG}/getUpdates?offset=-300&limit=300&allowed_updates=[\"channel_post\",\"message\"]" 2>/dev/null || true)

# ════════════════════════════════════════════
# الخطوة 2: فحص الرسالة المثبّتة
# ════════════════════════════════════════════
echo "📌 فحص الرسالة المثبّتة..."
PINNED=$(curl -sS "${TG}/getChat?chat_id=${TG_CHAT_ID}" 2>/dev/null || true)
_pin_fname=$(echo "$PINNED" | jq -r '.result.pinned_message.document.file_name // empty' 2>/dev/null || true)
_pin_caption=$(echo "$PINNED" | jq -r '.result.pinned_message.caption // empty' 2>/dev/null || true)
_pin_fid=$(echo "$PINNED" | jq -r '.result.pinned_message.document.file_id // empty' 2>/dev/null || true)

echo "  📌 المثبّت: ${_pin_fname:-لا يوجد}"

# استخراج Backup ID
BACKUP_ID=""
for _src in "$_pin_caption" "$_pin_fname"; do
  BACKUP_ID=$(echo "$_src" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}' | head -1 || true)
  [ -n "$BACKUP_ID" ] && break
done
echo "  🆔 Backup ID: ${BACKUP_ID:-غير محدد}"

# ════════════════════════════════════════════
# الخطوة 2.5: ابحث عن ملف كامل حديث أولاً! ⭐
# ════════════════════════════════════════════
echo "🔍 هل يوجد باك أب كامل حديث؟"

_recent_full=$(echo "$ALL_UPDATES" | jq -r '
  [.result[]? | 
    (.channel_post // .message) |
    select(.document != null) |
    select(.document.file_name // "" | test("^db\\.sql\\.gz$")) |
    {file_id: .document.file_id, file_name: .document.file_name, date: .date}
  ] | sort_by(-.date) | .[0].file_id // empty
' 2>/dev/null || true)

if [ -n "$_recent_full" ]; then
  echo "  📄 وجدنا ملف كامل حديث!"
  if dl_file "$_recent_full" "$TMP/full_recent.gz"; then
    if restore_from_gz "$TMP/full_recent.gz"; then
      echo "🎉 تم استرجاع الملف الكامل الحديث!"
      exit 0
    fi
  fi
  echo "  ⚠️ فشل استرجاع الملف الكامل، نجرب الأجزاء..."
fi

# ════════════════════════════════════════════
# الخطوة 3: لو الملف المثبّت ملف واحد
# ════════════════════════════════════════════
if [ -n "$_pin_fid" ]; then
  _is_single=false
  if echo "$_pin_fname" | grep -q "db\.sql\.gz$" && \
     ! echo "$_pin_fname" | grep -q "part_"; then
    _is_single=true
  fi

  if [ "$_is_single" = "true" ]; then
    echo "  📄 ملف واحد مثبّت — استرجاع مباشر..."
    if dl_file "$_pin_fid" "$TMP/db.sql.gz"; then
      if restore_from_gz "$TMP/db.sql.gz"; then
        echo "🎉 تم من الرسالة المثبّتة!"
        exit 0
      fi
    fi
  fi
fi

# ════════════════════════════════════════════
# الخطوة 4: ابحث عن كل الأجزاء بنفس الـ BACKUP_ID
# ════════════════════════════════════════════
if [ -n "$BACKUP_ID" ]; then
  echo "🔍 البحث عن أجزاء الباك أب: $BACKUP_ID"

  # ✅ استخدام ALL_UPDATES اللي جبناه فوق
  _parts_list="$TMP/parts_list.txt"
  > "$_parts_list"
  
  echo "$ALL_UPDATES" | jq -r --arg bid "$BACKUP_ID" '
    .result[]? | 
    (.channel_post // .message) |
    select(.document != null) |
    select(
      (.document.file_name // "" | contains($bid)) or
      (.caption // "" | contains($bid))
    ) |
    "\(.document.file_id)|\(.document.file_name)"
  ' 2>/dev/null | sort -t'|' -k2 > "$_parts_list"

  TOTAL_PARTS=$(wc -l < "$_parts_list" | tr -d ' ')
  
  if [ "$TOTAL_PARTS" -gt 0 ]; then
    echo "  📦 وجدنا $TOTAL_PARTS جزء"
    PART_COUNT=0
    ALL_DOWNLOADED=true

    # ✅ while مع < (مو pipe!) - المتغيرات تتحدث صح
    while IFS='|' read -r _fid _fname; do
      [ -n "$_fid" ] || continue
      echo "  📥 [$((PART_COUNT + 1))/$TOTAL_PARTS] تحميل: $_fname"
      
      if dl_file "$_fid" "$TMP/parts/$_fname"; then
        PART_COUNT=$((PART_COUNT + 1))
        echo "  ✅ تم: $_fname"
      else
        echo "  ❌ فشل: $_fname"
        ALL_DOWNLOADED=false
      fi
    done < "$_parts_list"

    echo "  📊 تم تحميل $PART_COUNT من $TOTAL_PARTS جزء"

    # تجميع الأجزاء
    if [ "$PART_COUNT" -gt 0 ] && [ "$ALL_DOWNLOADED" = "true" ]; then
      echo "  🔗 تجميع الأجزاء..."
      
      _combined="$TMP/db.sql.gz"
      > "$_combined"

      # ترتيب الأجزاء حسب الاسم
      for _part in $(ls "$TMP/parts/"* 2>/dev/null | sort); do
        echo "    ➕ $(basename "$_part")"
        cat "$_part" >> "$_combined"
      done

      if [ -s "$_combined" ]; then
        _size=$(stat -c%s "$_combined" 2>/dev/null || stat -f%z "$_combined" 2>/dev/null || echo 0)
        echo "  💾 الحجم: $((_size / 1024 / 1024))M"
        
        if restore_from_gz "$_combined"; then
          echo "🎉 تم استرجاع الأجزاء المجمّعة!"
          exit 0
        else
          # محاولة بديلة
          gzip -d < "$_combined" | sqlite3 "$N8N_DIR/database.sqlite" 2>/dev/null && {
            echo "🎉 تم بالطريقة البديلة!"
            exit 0
          }
        fi
      fi
    fi
  else
    echo "  ⚠️ ما وجدنا أجزاء بالـ ID: $BACKUP_ID"
  fi
fi

# ════════════════════════════════════════════
# الخطوة 5: بحث شامل - أي ملف db.sql.gz (محاولة أخيرة)
# ════════════════════════════════════════════
echo "🔍 محاولة أخيرة - أي باك أب..."

_db_fid=$(echo "$ALL_UPDATES" | jq -r '
  [.result[]? | 
    (.channel_post // .message) |
    select(.document != null) |
    select(
      (.document.file_name // "" | test("db\\.sql\\.gz")) or
      (.caption // "" | test("n8n_backup"))
    )
  ] | sort_by(-.date) | .[0].document.file_id // empty
' 2>/dev/null || true)

if [ -n "$_db_fid" ]; then
  echo "  📋 وجدنا ملف!"
  if dl_file "$_db_fid" "$TMP/last_resort.gz"; then
    if restore_from_gz "$TMP/last_resort.gz"; then
      echo "🎉 تم!"
      exit 0
    fi
  fi
fi

echo "📭 ما لقينا نسخة قابلة للاسترجاع"
exit 1
