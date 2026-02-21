#!/bin/sh
set -eu
umask 077

: "${TG_BOT_TOKEN:?}"
: "${TG_CHAT_ID:?}"

N8N_DIR="${N8N_DIR:-/home/node/.n8n}"
WORK="${WORK:-/backup-data}"
HIST="$WORK/history"

TG="https://api.telegram.org/bot${TG_BOT_TOKEN}"
TMP="/tmp/restore-$$"

trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT
mkdir -p "$N8N_DIR" "$WORK" "$HIST" "$TMP"

[ -s "$N8N_DIR/database.sqlite" ] && { echo "✅ DB موجودة"; exit 0; }

echo "=== 🔍 البحث عن آخر باك أب ==="

dl_file() {
  _fid="$1"; _out="$2"
  _path=$(curl -sS "${TG}/getFile?file_id=${_fid}" | jq -r '.result.file_path // empty' 2>/dev/null)
  [ -n "$_path" ] || return 1
  curl -sS -o "$_out" "https://api.telegram.org/file/bot${TG_BOT_TOKEN}/${_path}"
  [ -s "$_out" ]
}

restore_from_manifest() {
  _mfile="$1"
  _bid=$(jq -r '.id // "?"' "$_mfile" 2>/dev/null)
  echo "  📋 باك أب: $_bid"

  _rdir="$TMP/data"
  rm -rf "$_rdir"; mkdir -p "$_rdir"

  jq -r '.files[] | "\(.file_id)|\(.name)"' "$_mfile" 2>/dev/null | while IFS='|' read -r _fid _fn; do
    [ -n "$_fid" ] || continue
    echo "    📥 $_fn..."
    _try=0
    while [ "$_try" -lt 3 ]; do
      if dl_file "$_fid" "$_rdir/$_fn"; then echo "      ✅"; break; fi
      _try=$((_try + 1))
      sleep 2
    done
    [ -s "$_rdir/$_fn" ] || touch "$_rdir/.failed"
    sleep 1
  done

  [ ! -f "$_rdir/.failed" ] || { echo "  ❌ فشل التحميل"; return 1; }

  if ls "$_rdir"/db.sql.gz.part_* >/dev/null 2>&1; then
    cat "$_rdir"/db.sql.gz.part_* | gzip -dc | sqlite3 "$N8N_DIR/database.sqlite"
  elif [ -f "$_rdir/db.sql.gz" ]; then
    gzip -dc "$_rdir/db.sql.gz" | sqlite3 "$N8N_DIR/database.sqlite"
  else
    echo "  ❌ لا ملفات DB"; return 1
  fi

  if [ ! -s "$N8N_DIR/database.sqlite" ]; then echo "  ❌ DB فارغة"; rm -f "$N8N_DIR/database.sqlite"; return 1; fi

  _tc=$(sqlite3 "$N8N_DIR/database.sqlite" "SELECT count(*) FROM sqlite_master WHERE type='table';" 2>/dev/null || echo 0)
  [ "$_tc" -gt 0 ] || { rm -f "$N8N_DIR/database.sqlite"; return 1; }
  echo "  ✅ $_tc جدول"

  if ls "$_rdir"/files.tar.gz.part_* >/dev/null 2>&1; then
    cat "$_rdir"/files.tar.gz.part_* | gzip -dc | tar -C "$N8N_DIR" -xf - 2>/dev/null || true
  elif [ -f "$_rdir/files.tar.gz" ]; then
    gzip -dc "$_rdir/files.tar.gz" | tar -C "$N8N_DIR" -xf - 2>/dev/null || true
  fi

  cp "$_mfile" "$HIST/${_bid}.json" 2>/dev/null || true
  rm -rf "$_rdir"
  echo "  🎉 استرجاع ناجح!"
  return 0
}

echo "\n🔍 [1/2] البحث عن رسالة مثبّتة..."
PINNED=$(curl -sS "${TG}/getChat?chat_id=${TG_CHAT_ID}" 2>/dev/null)
_pin_fid=$(echo "$PINNED" | jq -r '.result.pinned_message.document.file_id // empty' 2>/dev/null)
_pin_cap=$(echo "$PINNED" | jq -r '.result.pinned_message.caption // ""' 2>/dev/null)

if [ -n "$_pin_fid" ] && echo "$_pin_cap" | grep -q "n8n_manifest"; then
  echo "  📌 لقينا مانيفست مثبّت!"
  if dl_file "$_pin_fid" "$TMP/manifest.json"; then
    if restore_from_manifest "$TMP/manifest.json"; then exit 0; fi
  fi
fi

echo "\n🔍 [2/2] البحث في آخر الرسائل..."
_search_resp=$(curl -sS "${TG}/getUpdates?offset=-50&limit=50" 2>/dev/null || true)
if [ -n "$_search_resp" ]; then
  _found_fid=$(echo "$_search_resp" | jq -r '
    [.result[] | select(.channel_post.document != null) | select(.channel_post.caption // "" | contains("n8n_manifest"))
    ] | sort_by(-.channel_post.date) | .[0].channel_post.document.file_id // empty
  ' 2>/dev/null || true)

  if [ -n "$_found_fid" ]; then
    echo "  📋 لقينا مانيفست!"
    if dl_file "$_found_fid" "$TMP/manifest2.json"; then
      if restore_from_manifest "$TMP/manifest2.json"; then exit 0; fi
    fi
  fi
fi

echo "\n📭 لا توجد نسخة احتياطية"
exit 1
