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

if [ -s "$N8N_DIR/database.sqlite" ]; then
  _tc=$(sqlite3 "$N8N_DIR/database.sqlite" \
    "SELECT count(*) FROM sqlite_master WHERE type='table';" 2>/dev/null || echo 0)
  if [ "$_tc" -gt 0 ]; then
    echo "✅ DB موجودة ($_tc جدول)"
    exit 0
  fi
  rm -f "$N8N_DIR/database.sqlite"
fi

echo "=== 🔍 البحث عن db.sql.gz ==="

dl_file() {
  _fid="$1"; _out="$2"
  _path=$(curl -sS "${TG}/getFile?file_id=${_fid}" \
    | jq -r '.result.file_path // empty' 2>/dev/null)
  [ -n "$_path" ] || return 1
  curl -sS -o "$_out" \
    "https://api.telegram.org/file/bot${TG_BOT_TOKEN}/${_path}"
  [ -s "$_out" ]
}

restore_db() {
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
    echo "  ✅ $_tc جدول"
    return 0
  fi
  rm -f "$N8N_DIR/database.sqlite"
  return 1
}

# ════════════════════════════════
# الرسالة المثبّتة
# ════════════════════════════════
echo "🔍 الرسالة المثبّتة..."

PINNED=$(curl -sS "${TG}/getChat?chat_id=${TG_CHAT_ID}" 2>/dev/null || true)
_pin_fid=$(echo "$PINNED" | jq -r '.result.pinned_message.document.file_id // empty' 2>/dev/null || true)
_pin_fname=$(echo "$PINNED" | jq -r '.result.pinned_message.document.file_name // empty' 2>/dev/null || true)

if [ -n "$_pin_fid" ]; then
  echo "  📌 ملف: $_pin_fname"

  if dl_file "$_pin_fid" "$TMP/pinned_file"; then
    # لو db.sql.gz مباشرة
    if gzip -t "$TMP/pinned_file" 2>/dev/null; then
      if restore_db "$TMP/pinned_file"; then
        echo "  🎉 تم من المثبّت!"
        exit 0
      fi
    fi
  fi
fi

# ════════════════════════════════
# البحث بـ getUpdates
# ════════════════════════════════
echo "🔍 البحث في الرسائل..."

_resp=$(curl -sS "${TG}/getUpdates?offset=-100&limit=100&allowed_updates=[\"channel_post\"]" 2>/dev/null || true)
_ok=$(echo "$_resp" | jq -r '.ok // "false"' 2>/dev/null || true)

if [ "$_ok" = "true" ]; then
  _db_fid=$(echo "$_resp" | jq -r '
    [.result[] |
      select(.channel_post.document != null) |
      select(
        (.channel_post.document.file_name // "" | test("db\\.sql\\.gz")) or
        (.channel_post.caption // "" | test("n8n_backup"))
      )
    ] | sort_by(-.channel_post.date) | .[0].channel_post.document.file_id // empty
  ' 2>/dev/null || true)

  if [ -n "$_db_fid" ]; then
    echo "  📋 لقينا ملف!"
    if dl_file "$_db_fid" "$TMP/found_db"; then
      if gzip -t "$TMP/found_db" 2>/dev/null; then
        if restore_db "$TMP/found_db"; then
          echo "  🎉 تم!"
          exit 0
        fi
      fi
    fi
  fi
fi

echo "📭 ما لقينا نسخة"
exit 1
