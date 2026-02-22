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

# لو الداتابيس موجودة وصالحة - لا نسوي شي
if [ -s "$N8N_DIR/database.sqlite" ]; then
  _tc=$(sqlite3 "$N8N_DIR/database.sqlite" \
    "SELECT count(*) FROM sqlite_master WHERE type='table';" 2>/dev/null || echo 0)
  if [ "$_tc" -gt 0 ]; then
    echo "✅ DB موجودة وصالحة ($_tc جدول)"
    exit 0
  fi
  echo "⚠️ DB موجودة لكن فارغة - نسترجع..."
  rm -f "$N8N_DIR/database.sqlite"
fi

echo "=== 🔍 البحث عن آخر db.sql.gz ==="

# ══════════════════════════════════════════
# دالة: تحميل ملف من تلكرام بواسطة file_id
# ══════════════════════════════════════════
dl_file() {
  _fid="$1"; _out="$2"
  _path=$(curl -sS "${TG}/getFile?file_id=${_fid}" \
    | jq -r '.result.file_path // empty' 2>/dev/null)
  [ -n "$_path" ] || return 1
  curl -sS -o "$_out" \
    "https://api.telegram.org/file/bot${TG_BOT_TOKEN}/${_path}"
  [ -s "$_out" ]
}

# ══════════════════════════════════════════
# دالة: استرجاع من ملف db.sql.gz
# ══════════════════════════════════════════
restore_db() {
  _dbgz="$1"
  echo "  📦 استرجاع الداتابيس..."

  # تأكد انه ملف gzip صالح
  if ! gzip -t "$_dbgz" 2>/dev/null; then
    echo "  ❌ ملف gz تالف"
    return 1
  fi

  gzip -dc "$_dbgz" | sqlite3 "$N8N_DIR/database.sqlite" 2>/dev/null

  if [ ! -s "$N8N_DIR/database.sqlite" ]; then
    echo "  ❌ DB فارغة بعد الاسترجاع"
    rm -f "$N8N_DIR/database.sqlite"
    return 1
  fi

  _tc=$(sqlite3 "$N8N_DIR/database.sqlite" \
    "SELECT count(*) FROM sqlite_master WHERE type='table';" 2>/dev/null || echo 0)

  if [ "$_tc" -gt 0 ]; then
    echo "  ✅ نجح! $_tc جدول"
    return 0
  else
    echo "  ❌ لا جداول"
    rm -f "$N8N_DIR/database.sqlite"
    return 1
  fi
}

# ══════════════════════════════════════════
# دالة: استرجاع من أجزاء مقسمة
# ══════════════════════════════════════════
restore_parts() {
  _dir="$1"
  echo "  📦 تجميع الأجزاء..."

  if ls "$_dir"/db.sql.gz.part_* >/dev/null 2>&1; then
    cat "$_dir"/db.sql.gz.part_* > "$_dir/db.sql.gz.combined"
    if restore_db "$_dir/db.sql.gz.combined"; then
      return 0
    fi
  fi
  return 1
}

# ════════════════════════════════════════════════
# الطريقة 1: الرسالة المثبّتة (الأهم)
# ════════════════════════════════════════════════
echo ""
echo "🔍 [1/3] البحث في الرسالة المثبّتة..."

PINNED=$(curl -sS "${TG}/getChat?chat_id=${TG_CHAT_ID}" 2>/dev/null || true)
_pin_fid=$(echo "$PINNED" | jq -r '.result.pinned_message.document.file_id // empty' 2>/dev/null || true)
_pin_fname=$(echo "$PINNED" | jq -r '.result.pinned_message.document.file_name // empty' 2>/dev/null || true)
_pin_cap=$(echo "$PINNED" | jq -r '.result.pinned_message.caption // ""' 2>/dev/null || true)

if [ -n "$_pin_fid" ]; then
  echo "  📌 لقينا ملف مثبّت: $_pin_fname"

  # لو الملف اسمه db.sql.gz مباشرة
  if echo "$_pin_fname" | grep -qE '^db\.sql\.gz$'; then
    echo "  📥 تحميل db.sql.gz..."
    if dl_file "$_pin_fid" "$TMP/db.sql.gz"; then
      if restore_db "$TMP/db.sql.gz"; then
        echo "  🎉 تم الاسترجاع من الرسالة المثبّتة!"
        exit 0
      fi
    fi
  fi

  # لو الملف جزء (part)
  if echo "$_pin_fname" | grep -qE 'db\.sql\.gz\.part_'; then
    echo "  📥 الملف جزء - نحتاج باقي الأجزاء..."
    # نكمل بالطريقة 2
  fi

  # لو ملف غير معروف - نجرب نشوف لو هو gzip
  if [ -z "$_pin_fname" ] || echo "$_pin_cap" | grep -q "n8n_backup"; then
    echo "  📥 تحميل وتجربة..."
    if dl_file "$_pin_fid" "$TMP/pinned_file"; then
      # نشوف لو gzip
      if gzip -t "$TMP/pinned_file" 2>/dev/null; then
        cp "$TMP/pinned_file" "$TMP/db.sql.gz"
        if restore_db "$TMP/db.sql.gz"; then
          echo "  🎉 تم الاسترجاع!"
          exit 0
        fi
      fi
    fi
  fi
fi
echo "  📭 ما نفع من المثبّت"

# ════════════════════════════════════════════════
# الطريقة 2: البحث في آخر 100 رسالة بالقناة
# ════════════════════════════════════════════════
echo ""
echo "🔍 [2/3] البحث في رسائل القناة..."

# نستخدم getUpdates مع channel posts
# أو نبحث عن الرسائل بطريقة forwardMessage

# الطريقة الأفضل: نستخدم القناة كـ chat ونقرأ آخر الرسائل
# Telegram Bot API ما يدعم قراءة تاريخ القناة مباشرة
# لكن نقدر نستخدم getUpdates

_offset=-1
_found=false
_search_tries=0

while [ "$_search_tries" -lt 5 ] && [ "$_found" = "false" ]; do
  _resp=$(curl -sS "${TG}/getUpdates?offset=${_offset}&limit=100&allowed_updates=[\"channel_post\"]" 2>/dev/null || true)
  _ok=$(echo "$_resp" | jq -r '.ok // "false"' 2>/dev/null || true)

  [ "$_ok" = "true" ] || break

  _count=$(echo "$_resp" | jq '.result | length' 2>/dev/null || echo 0)
  [ "$_count" -gt 0 ] || break

  # نبحث عن db.sql.gz بالرسائل (من الأحدث للأقدم)
  _db_fid=$(echo "$_resp" | jq -r '
    [.result[] |
      select(.channel_post.document != null) |
      select(
        (.channel_post.document.file_name // "" | test("^db\\.sql\\.gz$")) or
        (.channel_post.caption // "" | test("n8n_backup"))
      )
    ] | sort_by(-.channel_post.date) | .[0].channel_post.document.file_id // empty
  ' 2>/dev/null || true)

  _db_fname=$(echo "$_resp" | jq -r '
    [.result[] |
      select(.channel_post.document != null) |
      select(
        (.channel_post.document.file_name // "" | test("^db\\.sql\\.gz$")) or
        (.channel_post.caption // "" | test("n8n_backup"))
      )
    ] | sort_by(-.channel_post.date) | .[0].channel_post.document.file_name // empty
  ' 2>/dev/null || true)

  if [ -n "$_db_fid" ]; then
    echo "  📋 لقينا: $_db_fname"
    if dl_file "$_db_fid" "$TMP/found_db.sql.gz"; then
      if gzip -t "$TMP/found_db.sql.gz" 2>/dev/null; then
        if restore_db "$TMP/found_db.sql.gz"; then
          _found=true
          echo "  🎉 تم الاسترجاع من رسائل القناة!"
          exit 0
        fi
      fi
    fi
  fi

  # نحدث الـ offset
  _last_uid=$(echo "$_resp" | jq -r '.result[-1].update_id // empty' 2>/dev/null || true)
  [ -n "$_last_uid" ] && _offset=$((_last_uid + 1))

  _search_tries=$((_search_tries + 1))
done

echo "  📭 ما لقينا بالرسائل"

# ════════════════════════════════════════════════
# الطريقة 3: تحميل بـ file_id محفوظ محلياً
# ════════════════════════════════════════════════
echo ""
echo "🔍 [3/3] البحث في الملفات المحلية..."

if [ -f "$WORK/.backup_state" ]; then
  echo "  📋 لقينا حالة محلية"
  _saved_id=$(grep '^ID=' "$WORK/.backup_state" 2>/dev/null | cut -d= -f2 || true)
  echo "  آخر باك أب: $_saved_id"
fi

echo ""
echo "📭 لا توجد نسخة احتياطية قابلة للاسترجاع"
echo "🆕 سيبدأ n8n كتثبيت جديد"
exit 1
