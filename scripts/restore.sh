#!/bin/sh
set -eu
umask 077

: "${TG_BOT_TOKEN:?}" "${TG_CHAT_ID:?}"

N8N_DIR="${N8N_DIR:-/home/node/.n8n}"
WORK="${WORK:-/backup-data}"
HIST="$WORK/history"
TG="https://api.telegram.org/bot${TG_BOT_TOKEN}"
TMP="/tmp/restore_$$"

trap 'rm -rf "$TMP"' EXIT
mkdir -p "$N8N_DIR" "$WORK" "$HIST" "$TMP"

[ -s "$N8N_DIR/database.sqlite" ] && { echo "✅ DB موجودة"; exit 0; }

echo "🔍 البحث عن نسخة احتياطية..."

# ══════════════════════════════
# تحميل ملف من تلكرام
# ══════════════════════════════

download_file() {
  _fid="$1"
  _output="$2"

  _path=$(curl -sS "${TG}/getFile?file_id=${_fid}" 2>/dev/null \
    | jq -r '.result.file_path // empty')

  [ -z "$_path" ] && return 1

  curl -sS -o "$_output" \
    "https://api.telegram.org/file/bot${TG_BOT_TOKEN}/${_path}" 2>/dev/null

  [ -s "$_output" ]
}

# ══════════════════════════════
# استرجاع من manifest
# ══════════════════════════════

restore_from_manifest() {
  _manifest="$1"
  _bid=$(jq -r '.id // "?"' "$_manifest")
  
  echo "  📋 استرجاع: $_bid"

  # تحميل الملفات
  jq -c '.files[]' "$_manifest" 2>/dev/null | while read -r obj; do
    _fid=$(echo "$obj" | jq -r '.file_id // .f // empty')
    _fname=$(echo "$obj" | jq -r '.name // .n // empty')
    _mid=$(echo "$obj" | jq -r '.msg_id // .m // 0')

    [ -z "$_fid" ] || [ -z "$_fname" ] && continue

    echo "    📥 $_fname"

    # طريقة 1: file_id مباشرة
    if download_file "$_fid" "$TMP/$_fname" 2>/dev/null; then
      continue
    fi

    # طريقة 2: forward الرسالة
    if [ "$_mid" != "0" ]; then
      _fwd=$(curl -sS -X POST "${TG}/forwardMessage" \
        -d "chat_id=${TG_CHAT_ID}" \
        -d "from_chat_id=${TG_CHAT_ID}" \
        -d "message_id=${_mid}" 2>/dev/null || true)

      _new_fid=$(echo "$_fwd" | jq -r '.result.document.file_id // empty')
      _fwd_mid=$(echo "$_fwd" | jq -r '.result.message_id // empty')

      # حذف الفورورد
      [ -n "$_fwd_mid" ] && curl -sS -X POST "${TG}/deleteMessage" \
        -d "chat_id=${TG_CHAT_ID}" -d "message_id=${_fwd_mid}" >/dev/null 2>&1 || true

      [ -n "$_new_fid" ] && download_file "$_new_fid" "$TMP/$_fname" 2>/dev/null
    fi

    sleep 1
  done

  # استرجاع DB
  if [ -f "$TMP/db.sql.gz" ]; then
    gzip -dc "$TMP/db.sql.gz" | sqlite3 "$N8N_DIR/database.sqlite"
  elif ls "$TMP"/db.sql.gz.part_* >/dev/null 2>&1; then
    cat "$TMP"/db.sql.gz.part_* | gzip -dc | sqlite3 "$N8N_DIR/database.sqlite"
  else
    echo "  ❌ لا توجد DB"
    return 1
  fi

  # فحص
  _tables=$(sqlite3 "$N8N_DIR/database.sqlite" \
    "SELECT count(*) FROM sqlite_master WHERE type='table';" 2>/dev/null || echo 0)

  [ "$_tables" -eq 0 ] && {
    rm -f "$N8N_DIR/database.sqlite"
    echo "  ❌ DB فارغة"
    return 1
  }

  echo "  ✅ $_tables جدول"

  # استرجاع الملفات
  if [ -f "$TMP/files.tar.gz" ]; then
    gzip -dc "$TMP/files.tar.gz" | tar -C "$N8N_DIR" -xf - 2>/dev/null || true
  elif ls "$TMP"/files.tar.gz.part_* >/dev/null 2>&1; then
    cat "$TMP"/files.tar.gz.part_* | gzip -dc | tar -C "$N8N_DIR" -xf - 2>/dev/null || true
  fi

  cp "$_manifest" "$HIST/${_bid}.json" 2>/dev/null || true
  echo "  🎉 تم بنجاح!"
  return 0
}

# ══════════════════════════════
# البحث عن manifest
# ══════════════════════════════

# **الطريقة الجديدة**: نبحث في آخر 100 message
# (يشتغل إذا البوت admin بالقناة أو الرسائل forwarded)

echo "🔍 البحث في الرسائل..."

# نجرب نحصل آخر 100 update_id
for offset in -1 -50 -100; do
  MSGS=$(curl -sS "${TG}/getUpdates?offset=${offset}&limit=100" 2>/dev/null || true)
  
  # نبحث عن manifest
  _fid=$(echo "$MSGS" | jq -r '
    [.result[]? 
      | select(
          (.message.document != null or .channel_post.document != null)
          and ((.message.caption // .channel_post.caption // "") | contains("n8n_manifest"))
        )
    ] 
    | sort_by(-(.message.date // .channel_post.date // 0))
    | .[0].message.document.file_id // .[0].channel_post.document.file_id // empty
  ' 2>/dev/null)

  if [ -n "$_fid" ]; then
    echo "  ✅ لقيت manifest!"
    if download_file "$_fid" "$TMP/manifest.json"; then
      restore_from_manifest "$TMP/manifest.json" && exit 0
    fi
  fi
done

echo "📭 لا توجد نسخة"
exit 1
