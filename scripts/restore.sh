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
    echo "✅ DB موجودة ($_tc جدول)"; exit 0
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
    echo "  ❌ ملف تالف"; return 1
  fi
  gzip -dc "$_dbgz" | sqlite3 "$N8N_DIR/database.sqlite" 2>/dev/null
  if [ ! -s "$N8N_DIR/database.sqlite" ]; then
    rm -f "$N8N_DIR/database.sqlite"; return 1
  fi
  _tc=$(sqlite3 "$N8N_DIR/database.sqlite" \
    "SELECT count(*) FROM sqlite_master WHERE type='table';" 2>/dev/null || echo 0)
  if [ "$_tc" -gt 0 ]; then
    echo "  ✅ $_tc جدول — تم الاسترجاع!"; return 0
  fi
  rm -f "$N8N_DIR/database.sqlite"; return 1
}

# ════════════════════════════════════════════
# الخطوة 1: الرسالة المثبّتة
# ════════════════════════════════════════════
echo "📌 فحص الرسالة المثبّتة..."
PINNED=$(curl -sS "${TG}/getChat?chat_id=${TG_CHAT_ID}" 2>/dev/null || true)

_pin_fname=$(echo "$PINNED"   | jq -r '.result.pinned_message.document.file_name // empty' 2>/dev/null || true)
_pin_fid=$(echo "$PINNED"     | jq -r '.result.pinned_message.document.file_id   // empty' 2>/dev/null || true)
_pin_caption=$(echo "$PINNED" | jq -r '.result.pinned_message.caption // empty' 2>/dev/null || true)
_pin_text=$(echo "$PINNED"    | jq -r '.result.pinned_message.text    // empty' 2>/dev/null || true)

_pin_all_text="${_pin_caption} ${_pin_text} ${_pin_fname}"
echo "  📌 الملف المثبّت: ${_pin_fname:-رسالة نصية}"

BACKUP_ID=$(echo "$_pin_all_text" \
  | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}' \
  | head -1 || true)
echo "  🆔 Backup ID: ${BACKUP_ID:-غير محدد}"

# ════════════════════════════════════════════
# الخطوة 2: ملف واحد مباشر
# ════════════════════════════════════════════
if [ -n "$_pin_fid" ]; then
  _is_single=false
  case "$_pin_fname" in
    db.sql.gz) _is_single=true ;;
    *part_*)   _is_single=false ;;
    *.sql.gz)  _is_single=true ;;
  esac

  if [ "$_is_single" = "true" ]; then
    echo "  📄 ملف واحد — استرجاع مباشر..."
    if dl_file "$_pin_fid" "$TMP/db.sql.gz"; then
      if restore_from_gz "$TMP/db.sql.gz"; then
        echo "🎉 تم من الرسالة المثبّتة!"; exit 0
      fi
    fi
  fi
fi

# ════════════════════════════════════════════
# الخطوة 3: تحميل الأجزاء بنفس BACKUP_ID
# ════════════════════════════════════════════
if [ -n "$BACKUP_ID" ]; then
  echo "🔍 البحث عن أجزاء: $BACKUP_ID"

  _raw=$(curl -sS "${TG}/getUpdates?limit=100" 2>/dev/null || true)

  echo "$_raw" | jq -r '
    .result[]? |
    (.channel_post // .message) |
    select(.document != null) |
    select(.caption? // "" | contains("'"$BACKUP_ID"'")) |
    "\(.document.file_id)\t\(.document.file_name)"
  ' 2>/dev/null > "$TMP/msgs.txt" || true

  if [ -s "$TMP/msgs.txt" ]; then
    echo "  📦 وجدنا أجزاء — تحميل..."
    sort -t"$(printf '\t')" -k2 "$TMP/msgs.txt" > "$TMP/msgs_sorted.txt"

    while IFS="$(printf '\t')" read -r _fid _fname; do
      [ -n "$_fid" ] || continue
      echo "    📥 تحميل: $_fname"
      dl_file "$_fid" "$TMP/parts/$_fname" \
        && echo "    ✅ تم" || echo "    ⚠️ فشل: $_fname"
    done < "$TMP/msgs_sorted.txt"

    _parts_count=$(find "$TMP/parts/" -name "*.part_*" -type f 2>/dev/null | wc -l | tr -d ' ')
    if [ "$_parts_count" -gt 0 ]; then
      echo "  🔗 تجميع $_parts_count أجزاء..."

      # FIX #1: بدل pipe | while (subshell يمنع _first من التحديث)
      # نكتب قائمة الملفات لـ file ثم نلوب بـ < (نفس الـ shell)
      find "$TMP/parts/" -name "*.part_*" -type f | sort > "$TMP/parts_to_join.txt"

      _first=true
      while IFS= read -r _pf; do
        if [ "$_first" = "true" ]; then
          cat "$_pf"  > "$TMP/db.sql.gz"
          _first=false
        else
          cat "$_pf" >> "$TMP/db.sql.gz"
        fi
      done < "$TMP/parts_to_join.txt"
      # الآن _first يتحدث صح لأننا في نفس الـ shell بلا pipe

      if [ -s "$TMP/db.sql.gz" ]; then
        if restore_from_gz "$TMP/db.sql.gz"; then
          echo "🎉 تم من الأجزاء المجمّعة!"; exit 0
        fi
      fi
    fi
  fi
fi

# ════════════════════════════════════════════
# الخطوة 4: بحث شامل
# ════════════════════════════════════════════
echo "🔍 بحث شامل..."

_db_fid=$(curl -sS "${TG}/getUpdates?limit=100" 2>/dev/null | \
  jq -r '
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
  if dl_file "$_db_fid" "$TMP/db_found.sql.gz"; then
    if restore_from_gz "$TMP/db_found.sql.gz"; then
      echo "🎉 تم!"; exit 0
    fi
  fi
fi

echo "📭 ما لقينا نسخة قابلة للاسترجاع"
exit 1
