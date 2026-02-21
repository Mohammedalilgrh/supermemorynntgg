#!/bin/bash
set -eu
umask 077

: "${TG_BOT_TOKEN:?}"
: "${TG_CHAT_ID:?}"

N8N_DIR="${N8N_DIR:-/home/node/.n8n}"
WORK="${WORK:-/backup-data}"
HIST="$WORK/history"
TG="https://api.telegram.org/bot${TG_BOT_TOKEN}"
TMP="$WORK/_restore_tmp"

trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT
mkdir -p "$N8N_DIR" "$WORK" "$HIST"
rm -rf "$TMP" 2>/dev/null || true
mkdir -p "$TMP"

if [ -s "$N8N_DIR/database.sqlite" ]; then
  _tc=$(sqlite3 "$N8N_DIR/database.sqlite" \
    "SELECT count(*) FROM sqlite_master WHERE type='table';" 2>/dev/null || echo 0)
  if [ "$_tc" -gt 5 ]; then
    echo "✅ DB موجودة ($_tc)"
    exit 0
  fi
fi

echo "=== 🔍 باك أب ==="

dl_file() {
  _fid="$1" _out="$2" _mt="${3:-3}" _t=0
  while [ "$_t" -lt "$_mt" ]; do
    _p=$(curl -sS --max-time 15 "${TG}/getFile?file_id=${_fid}" 2>/dev/null | \
      jq -r '.result.file_path // empty' 2>/dev/null || true)
    if [ -n "$_p" ]; then
      curl -sS --max-time 120 -o "$_out" \
        "https://api.telegram.org/file/bot${TG_BOT_TOKEN}/${_p}" 2>/dev/null && \
        [ -s "$_out" ] && return 0
    fi
    _t=$((_t + 1)); sleep 3
  done
  return 1
}

restore_from_manifest() {
  _mfile="$1"
  jq empty "$_mfile" 2>/dev/null || { echo "❌ تالف"; return 1; }

  _bid=$(jq -r '.id // "?"' "$_mfile")
  _bdb=$(jq -r '.db_size // "?"' "$_mfile")
  echo "📋 $_bid | DB: $_bdb"

  _db_list=$(jq -r '.files[] | select(.name | startswith("db.")) | "\(.file_id)|\(.name)"' \
    "$_mfile" 2>/dev/null | sort -t'|' -k2 || true)
  [ -n "$_db_list" ] || { echo "❌ لا DB"; return 1; }

  _dbc=$(echo "$_db_list" | wc -l | tr -d ' ')
  echo "🗄️ $_dbc جزء"

  rm -f "$N8N_DIR/database.sqlite" "$N8N_DIR/database.sqlite-wal" \
        "$N8N_DIR/database.sqlite-shm" 2>/dev/null || true

  mkdir -p "$TMP/dbp"
  while IFS='|' read -r _fid _fn; do
    [ -n "$_fid" ] && [ -n "$_fn" ] || continue
    echo "  📥 $_fn"
    if dl_file "$_fid" "$TMP/dbp/$_fn" 3; then
      echo "  ✅ ($(du -h "$TMP/dbp/$_fn" | cut -f1))"
    else
      echo "  ❌"; touch "$TMP/dbp/.fail"
    fi
    sleep 1
  done <<< "$_db_list"

  [ ! -f "$TMP/dbp/.fail" ] || { rm -rf "$TMP/dbp"; return 1; }

  echo "🔧 بناء DB..."
  _ac=$(find "$TMP/dbp" -type f -name 'db.*' | wc -l)
  [ "$_ac" -gt 0 ] || { rm -rf "$TMP/dbp"; return 1; }

  if [ "$_ac" -eq 1 ]; then
    gzip -dc "$(find "$TMP/dbp" -type f -name 'db.*')" | \
      sqlite3 "$N8N_DIR/database.sqlite"
  else
    cat $(find "$TMP/dbp" -type f -name 'db.*' | sort) | \
      gzip -dc | sqlite3 "$N8N_DIR/database.sqlite"
  fi
  rm -rf "$TMP/dbp"

  [ -s "$N8N_DIR/database.sqlite" ] || { echo "❌ فارغة"; return 1; }

  _tc=$(sqlite3 "$N8N_DIR/database.sqlite" \
    "SELECT count(*) FROM sqlite_master WHERE type='table';" 2>/dev/null || echo 0)
  [ "$_tc" -gt 3 ] || { rm -f "$N8N_DIR/database.sqlite"; return 1; }

  _users=$(sqlite3 "$N8N_DIR/database.sqlite" \
    "SELECT count(*) FROM \"user\";" 2>/dev/null || echo 0)
  _wf=$(sqlite3 "$N8N_DIR/database.sqlite" \
    "SELECT count(*) FROM workflow_entity;" 2>/dev/null || echo 0)

  echo "✅ $_tc جدول | $_users مستخدم | $_wf workflow"

  # encryption key config
  if [ -n "${N8N_ENCRYPTION_KEY:-}" ]; then
    printf '{"encryptionKey":"%s"}' "$N8N_ENCRYPTION_KEY" > "$N8N_DIR/config"
    echo "🔐 config ✅"
  fi

  cp "$_mfile" "$HIST/${_bid}.json" 2>/dev/null || true
  rm -rf "$TMP"
  echo "🎉 $_bid"
  return 0
}

echo ""
echo "🔍 [1/3] مثبّتة..."
_chat=$(curl -sS --max-time 15 "${TG}/getChat?chat_id=${TG_CHAT_ID}" 2>/dev/null || true)
_pf=$(echo "$_chat" | jq -r '.result.pinned_message.document.file_id // empty' 2>/dev/null || true)
_pc=$(echo "$_chat" | jq -r '.result.pinned_message.caption // ""' 2>/dev/null || true)
if [ -n "$_pf" ] && echo "$_pc" | grep -q "n8n_manifest"; then
  echo "  📌!"
  dl_file "$_pf" "$TMP/m1.json" 3 && restore_from_manifest "$TMP/m1.json" && exit 0
fi

echo ""
echo "🔍 [2/3] رسائل..."
_upd=$(curl -sS --max-time 20 "${TG}/getUpdates?offset=-100&limit=100" 2>/dev/null || true)
_f2=""
[ -n "$_upd" ] && _f2=$(echo "$_upd" | jq -r '[.result[]|select((.channel_post.document!=null) and ((.channel_post.caption//"")|test("n8n_manifest")))]|sort_by(-.channel_post.date)|.[0].channel_post.document.file_id//empty' 2>/dev/null || true)
if [ -n "$_f2" ]; then
  dl_file "$_f2" "$TMP/m2.json" 3 && restore_from_manifest "$TMP/m2.json" && exit 0
fi

echo ""
echo "🔍 [3/3] محلي..."
_l=$(ls -t "$HIST"/*.json 2>/dev/null | head -1 || true)
[ -n "$_l" ] && [ -f "$_l" ] && restore_from_manifest "$_l" && exit 0

echo "📭 لا نسخة"
exit 0
