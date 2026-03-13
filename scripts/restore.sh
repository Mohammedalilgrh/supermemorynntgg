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
# الخطوة 1: جيب آخر 100 رسالة
# ════════════════════════════════════════════
echo "📥 جلب الرسائل..."

_resp=$(curl -sS "${TG}/getUpdates?offset=-100&limit=100&allowed_updates=[\"channel_post\",\"message\"]" \
  2>/dev/null || true)

# لو getUpdates ما رجّع شيء، جرب getChatHistory
_results=$(echo "$_resp" | jq -r '.result // []' 2>/dev/null)

# ════════════════════════════════════════════
# الخطوة 2: ابحث عن آخر باك أب وحدد ID تاعه
# ════════════════════════════════════════════

# أول شيء جرب الرسالة المثبّتة
echo "📌 فحص الرسالة المثبّتة..."
PINNED=$(curl -sS "${TG}/getChat?chat_id=${TG_CHAT_ID}" 2>/dev/null || true)
_pin_fname=$(echo "$PINNED" | jq -r '.result.pinned_message.document.file_name // empty' 2>/dev/null || true)
_pin_caption=$(echo "$PINNED" | jq -r '.result.pinned_message.caption // empty' 2>/dev/null || true)
_pin_fid=$(echo "$PINNED" | jq -r '.result.pinned_message.document.file_id // empty' 2>/dev/null || true)
_pin_msg_id=$(echo "$PINNED" | jq -r '.result.pinned_message.message_id // empty' 2>/dev/null || true)

echo "  📌 الرسالة المثبّتة: $_pin_fname"

# استخرج backup ID من الكابشن (صيغة: 2025-01-01_12-00-00)
BACKUP_ID=$(echo "$_pin_caption" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}' | head -1 || true)

if [ -z "$BACKUP_ID" ]; then
  # جرب من اسم الملف
  BACKUP_ID=$(echo "$_pin_fname" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}_[0-9]{2}-[0-9]{2}-[0-9]{2}' | head -1 || true)
fi

echo "  🆔 Backup ID: ${BACKUP_ID:-غير محدد}"

# ════════════════════════════════════════════
# الخطوة 3: لو الملف ملف واحد (db.sql.gz) — رجّع مباشرة
# ════════════════════════════════════════════
if [ -n "$_pin_fid" ]; then
  _is_single=false
  echo "$_pin_fname" | grep -q "db\.sql\.gz$" && ! echo "$_pin_fname" | grep -q "part_" && _is_single=true

  if [ "$_is_single" = "true" ]; then
    echo "  📄 ملف واحد — استرجاع مباشر..."
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

  # جلب الرسائل الأخيرة من القناة
  _msgs=$(curl -sS "${TG}/getUpdates?offset=-200&limit=200" 2>/dev/null | \
    jq -r '.result[]? | select(.channel_post.document != null) | 
    select(.channel_post.caption? // "" | contains("'"$BACKUP_ID"'")) |
    "\(.channel_post.document.file_id):\(.channel_post.document.file_name)"' \
    2>/dev/null || true)

  if [ -z "$_msgs" ]; then
    # جرب message بدل channel_post
    _msgs=$(curl -sS "${TG}/getUpdates?offset=-200&limit=200" 2>/dev/null | \
      jq -r '.result[]? | select(.message.document != null) | 
      select(.message.caption? // "" | contains("'"$BACKUP_ID"'")) |
      "\(.message.document.file_id):\(.message.document.file_name)"' \
      2>/dev/null || true)
  fi

  if [ -n "$_msgs" ]; then
    echo "  📦 وجدنا أجزاء!"
    PART_COUNT=0

    # رتّب الأجزاء حسب الاسم
    echo "$_msgs" | sort -t: -k2 | while IFS=: read -r _fid _fname; do
      echo "    📥 تحميل: $_fname"
      if dl_file "$_fid" "$TMP/parts/$_fname"; then
        echo "    ✅ تم: $_fname"
        PART_COUNT=$((PART_COUNT + 1))
      fi
    done

    # تجميع الأجزاء
    _part_files=$(ls "$TMP/parts/" 2>/dev/null | sort | grep "part_" || true)
    if [ -n "$_part_files" ]; then
      echo "  🔗 تجميع الأجزاء..."
      cat $(ls "$TMP/parts/"*.part_* 2>/dev/null | sort) > "$TMP/db.sql.gz" 2>/dev/null || true

      if [ -s "$TMP/db.sql.gz" ]; then
        if restore_from_gz "$TMP/db.sql.gz"; then
          echo "🎉 تم من الأجزاء المجمّعة!"
          exit 0
        fi
      fi
    fi
  fi
fi

# ════════════════════════════════════════════
# الخطوة 5: بحث شامل — أي ملف db.sql.gz
# ════════════════════════════════════════════
echo "🔍 بحث شامل..."

_db_fid=$(curl -sS "${TG}/getUpdates?offset=-100&limit=100" 2>/dev/null | \
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
      echo "🎉 تم!"
      exit 0
    fi
  fi
fi

echo "📭 ما لقينا نسخة قابلة للاسترجاع"
exit 1
