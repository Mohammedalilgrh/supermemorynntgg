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
# إذا فيه داتابيس شغالة - خلاص
# ════════════════════════════════════════════
if [ -s "$N8N_DIR/database.sqlite" ]; then
  _tc=$(sqlite3 "$N8N_DIR/database.sqlite" \
    "SELECT count(*) FROM sqlite_master WHERE type='table';" 2>/dev/null || echo 0)
  # بعدد جداول قليل يعني قاعدة فاضية!
  if [ "$_tc" -gt 5 ]; then
    echo "✅ DB موجودة ($_tc جدول)"
    exit 0
  fi
  echo "⚠️ قاعدة شبه فاضية ($_tc جدول) - جاري الاسترجاع..."
  rm -f "$N8N_DIR/database.sqlite"
fi

echo "=== 🔍 البحث عن باك أب ==="

# ════════════════════════════════════════════
# دالة التحميل
# ════════════════════════════════════════════
dl_file() {
  _fid="$1"; _out="$2"
  _path=$(curl -sS "${TG}/getFile?file_id=${_fid}" \
    | jq -r '.result.file_path // empty' 2>/dev/null)
  [ -n "$_path" ] || return 1
  curl -sS -o "$_out" \
    "https://api.telegram.org/file/bot${TG_BOT_TOKEN}/${_path}"
  [ -s "$_out" ]
}

# ════════════════════════════════════════════
# دالة الاسترجاع مع تجاهل الملفات الصغيرة
# ════════════════════════════════════════════
restore_from_gz() {
  _dbgz="$1"
  
  # ⭐ تجاهل الملفات أقل من 100KB (فاضية)
  _size=$(stat -c%s "$_dbgz" 2>/dev/null || stat -f%z "$_dbgz" 2>/dev/null || echo 0)
  if [ "$_size" -lt 102400 ]; then
    echo "  ⚠️ ملف صغير جداً (${_size} bytes) - تجاهل"
    return 1
  fi
  
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
  
  if [ "$_tc" -gt 5 ]; then
    echo "  ✅ $_tc جدول — تم الاسترجاع!"
    return 0
  fi
  
  echo "  ⚠️ قاعدة فاضية ($_tc جدول)"
  rm -f "$N8N_DIR/database.sqlite"
  return 1
}

# ════════════════════════════════════════════
# الخطوة 1: جلب كل الرسائل مرة وحدة
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

# ════════════════════════════════════════════
# الخطوة 2.5: ⭐ ابحث عن ملف كامل حديث أولاً
# ════════════════════════════════════════════
echo "🔍 البحث عن باك أب كامل حديث..."

_recent_full=$(echo "$ALL_UPDATES" | jq -r '
  [.result[]? | 
    (.channel_post // .message) |
    select(.document != null) |
    select(.document.file_name // "" | test("^db\\.sql\\.gz$")) |
    {
      file_id: .document.file_id,
      file_name: .document.file_name,
      file_size: .document.file_size,
      date: .date
    }
  ] | sort_by(-.date) | .[0]
' 2>/dev/null || true)

_recent_fid=$(echo "$_recent_full" | jq -r '.file_id // empty')
_recent_size=$(echo "$_recent_full" | jq -r '.file_size // 0')

# ⭐ لو الملف أكبر من 100KB - استرجعه فوراً
if [ -n "$_recent_fid" ] && [ "$_recent_size" -gt 102400 ]; then
  echo "  📄 وجدنا باك أب كامل ($((_recent_size / 1024))KB)"
  if dl_file "$_recent_fid" "$TMP/full_recent.gz"; then
    if restore_from_gz "$TMP/full_recent.gz"; then
      echo "🎉 تم استرجاع الملف الكامل الحديث!"
      exit 0
    fi
  fi
  echo "  ⚠️ فشل استرجاع الكامل، نجرب الأجزاء..."
else
  echo "  ℹ️ لا يوجد ملف كامل صالح"
fi

# ════════════════════════════════════════════
# الخطوة 3: لو المثبّت ملف واحد صالح
# ════════════════════════════════════════════
if [ -n "$_pin_fid" ]; then
  _is_single=false
  if echo "$_pin_fname" | grep -q "db\.sql\.gz$" && \
     ! echo "$_pin_fname" | grep -q "part_"; then
    _is_single=true
  fi

  if [ "$_is_single" = "true" ]; then
    echo "  📄 ملف واحد مثبّت — استرجاع..."
    if dl_file "$_pin_fid" "$TMP/db_pinned.gz"; then
      if restore_from_gz "$TMP/db_pinned.gz"; then
        echo "🎉 تم من المثبّت!"
        exit 0
      fi
    fi
  fi
fi

# ════════════════════════════════════════════
# الخطوة 4: ⭐ جمع الأجزاء (بدون pipe!)
# ════════════════════════════════════════════
# استخراج Backup ID من المثبّت أو أي جزء
BACKUP_ID=""
for _src in "$_pin_caption" "$_pin_fname"; do
  BACKUP_ID=$(echo "$_src" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}' | head -1 || true)
  [ -n "$BACKUP_ID" ] && break
done

if [ -z "$BACKUP_ID" ]; then
  # ما لقينا ID، جرب نبحث عن أي أجزاء
  echo "🔍 البحث عن أي أجزاء..."
  
  # خذ آخر part_000
  BACKUP_ID=$(echo "$ALL_UPDATES" | jq -r '
    [.result[]? | 
      (.channel_post // .message) |
      select(.document != null) |
      select(.document.file_name // "" | test("part_000$")) |
      .document.file_name
    ] | sort_by(.) | .[-1]
  ' 2>/dev/null | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}' | head -1 || true)
fi

if [ -n "$BACKUP_ID" ]; then
  echo "🔍 جمع أجزاء: $BACKUP_ID"

  # ✅ حفظ قائمة الأجزاء في ملف
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
    "\(.document.file_id)|\(.document.file_name)|\(.document.file_size // 0)"
  ' 2>/dev/null | sort -t'|' -k2 | uniq > "$_parts_list"

  TOTAL_PARTS=$(wc -l < "$_parts_list" | tr -d ' ')
  
  if [ "$TOTAL_PARTS" -gt 0 ]; then
    echo "  📦 وجدنا $TOTAL_PARTS جزء"
    PART_COUNT=0
    TOTAL_SIZE=0
    ALL_DOWNLOADED=true

    # ✅ while مع < (مو pipe!)
    while IFS='|' read -r _fid _fname _fsize; do
      [ -n "$_fid" ] || continue
      echo "  📥 [$((PART_COUNT + 1))/$TOTAL_PARTS] $_fname ($((_fsize / 1024))KB)"
      
      if dl_file "$_fid" "$TMP/parts/$_fname"; then
        PART_COUNT=$((PART_COUNT + 1))
        TOTAL_SIZE=$((TOTAL_SIZE + _fsize))
        echo "  ✅ تم"
      else
        echo "  ❌ فشل"
        ALL_DOWNLOADED=false
      fi
    done < "$_parts_list"

    echo "  📊 تم تحميل $PART_COUNT من $TOTAL_PARTS ($((TOTAL_SIZE / 1024 / 1024))MB)"

    # ⭐ لو الأجزاء أقل من 100KB - تجاهل
    if [ "$TOTAL_SIZE" -lt 102400 ]; then
      echo "  ⚠️ الأجزاء صغيرة جداً - تجاهل"
    elif [ "$PART_COUNT" -gt 0 ] && [ "$ALL_DOWNLOADED" = "true" ]; then
      echo "  🔗 تجميع..."
      
      _combined="$TMP/db.sql.gz"
      > "$_combined"

      # ترتيب حسب الاسم
      for _part in $(ls "$TMP/parts/"* 2>/dev/null | sort); do
        echo "    ➕ $(basename "$_part")"
        cat "$_part" >> "$_combined"
      done

      if [ -s "$_combined" ]; then
        _combined_size=$(stat -c%s "$_combined" 2>/dev/null || stat -f%z "$_combined" 2>/dev/null || echo 0)
        echo "  💾 المجموع: $((_combined_size / 1024 / 1024))MB"
        
        if restore_from_gz "$_combined"; then
          echo "🎉 تم!"
          exit 0
        fi
        
        # محاولة بديلة
        echo "  🔄 محاولة بديلة..."
        gzip -d < "$_combined" | sqlite3 "$N8N_DIR/database.sqlite" 2>/dev/null && {
          echo "🎉 تم بالبديلة!"
          exit 0
        }
      fi
    fi
  fi
fi

# ════════════════════════════════════════════
# الخطوة 5: محاولة أخيرة - أي ملف باك أب
# ════════════════════════════════════════════
echo "🔍 محاولة أخيرة..."

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
