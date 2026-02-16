#!/bin/sh
set -eu
umask 077

: "${TG_BOT_TOKEN:?}" "${TG_CHAT_ID:?}"

N8N_DIR="${N8N_DIR:-/home/node/.n8n}"
WORK="${WORK:-/backup-data}"
HIST="$WORK/history"

MIN_INTERVAL="${MIN_BACKUP_INTERVAL_SEC:-30}"
FORCE_INTERVAL="${FORCE_BACKUP_EVERY_SEC:-900}"
BACKUP_BINARY="${BACKUP_BINARYDATA:-true}"
CHUNK_SIZE="${CHUNK_SIZE_BYTES:-19000000}"

STATE="$WORK/.backup_state"
LOCK="$WORK/.backup_lock"
TMP="$WORK/_backup_tmp"
TG="https://api.telegram.org/bot${TG_BOT_TOKEN}"

mkdir -p "$WORK" "$HIST"

# ── قفل ──
mkdir "$LOCK" 2>/dev/null || { echo "⏳ باك أب ثاني شغّال"; exit 0; }
trap 'rmdir "$LOCK" 2>/dev/null; rm -rf "$TMP" 2>/dev/null' EXIT

# ══════════════════════════════
# كشف التغييرات
# ══════════════════════════════

get_db_signature() {
  _sig=""
  for _f in database.sqlite database.sqlite-wal database.sqlite-shm; do
    if [ -f "$N8N_DIR/$_f" ]; then
      _sig="${_sig}$(stat -c '%Y%s' "$N8N_DIR/$_f" 2>/dev/null);"
    fi
  done
  printf "%s" "$_sig"
}

get_binary_signature() {
  if [ "$BACKUP_BINARY" != "true" ]; then
    printf "skip"; return
  fi
  if [ ! -d "$N8N_DIR/binaryData" ]; then
    printf "none"; return
  fi
  du -sk "$N8N_DIR/binaryData" 2>/dev/null | awk '{print $1}'
}

check_if_needed() {
  [ -f "$N8N_DIR/database.sqlite" ] || { echo "NO_DB"; return; }

  _now=$(date +%s)
  _last_epoch=0
  _last_force=0
  _last_db_sig=""
  _last_bin_sig=""

  if [ -f "$STATE" ]; then
    _last_epoch=$(grep '^EPOCH=' "$STATE" 2>/dev/null | cut -d= -f2 || echo 0)
    _last_force=$(grep '^FORCE_EPOCH=' "$STATE" 2>/dev/null | cut -d= -f2 || echo 0)
    _last_db_sig=$(grep '^DB_SIG=' "$STATE" 2>/dev/null | cut -d= -f2- || true)
    _last_bin_sig=$(grep '^BIN_SIG=' "$STATE" 2>/dev/null | cut -d= -f2- || true)
  fi

  _cur_db=$(get_db_signature)
  _cur_bin=$(get_binary_signature)

  [ $((_now - _last_force)) -ge "$FORCE_INTERVAL" ] && { echo "FORCE"; return; }
  [ "$_cur_db" = "$_last_db_sig" ] && [ "$_cur_bin" = "$_last_bin_sig" ] && { echo "SAME"; return; }
  [ $((_now - _last_epoch)) -lt "$MIN_INTERVAL" ] && { echo "WAIT"; return; }

  echo "GO"
}

REASON=$(check_if_needed)
case "$REASON" in
  NO_DB|SAME|WAIT) exit 0 ;;
esac

# ══════════════════════════════
# بدء الباك أب
# ══════════════════════════════

BACKUP_ID=$(date +"%Y-%m-%d_%H-%M-%S")
BACKUP_TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

echo "📦 باك أب: $BACKUP_ID ($REASON)"

rm -rf "$TMP"
mkdir -p "$TMP/parts"

# ── 1. DB dump ──
sqlite3 "$N8N_DIR/database.sqlite" ".timeout 10000" \
  "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1 || true

sqlite3 "$N8N_DIR/database.sqlite" ".timeout 10000" ".dump" 2>/dev/null \
  | gzip -n -1 -c > "$TMP/db.sql.gz"

if [ ! -s "$TMP/db.sql.gz" ]; then
  echo "❌ فشل dump الداتابيس"
  exit 1
fi

DB_SIZE=$(du -h "$TMP/db.sql.gz" | cut -f1)

# ── 2. ملفات إضافية ──
_exclude="--exclude=database.sqlite --exclude=database.sqlite-wal --exclude=database.sqlite-shm"
[ "$BACKUP_BINARY" != "true" ] && _exclude="$_exclude --exclude=binaryData"

tar -C "$N8N_DIR" -cf - $_exclude . 2>/dev/null \
  | gzip -n -1 -c > "$TMP/files.tar.gz" || true

FILES_SIZE="0"
[ -s "$TMP/files.tar.gz" ] && FILES_SIZE=$(du -h "$TMP/files.tar.gz" | cut -f1)

# ── 3. تقسيم (كل جزء < 19MB) ──
for _src in db.sql.gz files.tar.gz; do
  [ -s "$TMP/$_src" ] || continue
  _sz=$(stat -c '%s' "$TMP/$_src" 2>/dev/null || echo 0)

  if [ "$_sz" -gt "$CHUNK_SIZE" ]; then
    split -b "$CHUNK_SIZE" -d -a 3 "$TMP/$_src" "$TMP/parts/${_src}.part_"
    rm -f "$TMP/$_src"
  else
    mv "$TMP/$_src" "$TMP/parts/$_src"
  fi
done

# ── 4. رفع لتلكرام ──
MANIFEST_FILES=""
FILE_COUNT=0
UPLOAD_OK=true

for _file in "$TMP/parts"/*; do
  [ -f "$_file" ] || continue
  _fname=$(basename "$_file")

  _retry=0
  _uploaded=""

  while [ "$_retry" -lt 3 ]; do
    _response=$(curl -sS -X POST "${TG}/sendDocument" \
      -F "chat_id=${TG_CHAT_ID}" \
      -F "document=@${_file}" \
      -F "caption=🗂 #n8n_backup ${BACKUP_ID} | ${_fname}" \
      2>/dev/null || true)

    _file_id=$(echo "$_response" | jq -r '.result.document.file_id // empty' 2>/dev/null || true)
    _msg_id=$(echo "$_response" | jq -r '.result.message_id // empty' 2>/dev/null || true)
    _ok=$(echo "$_response" | jq -r '.ok // "false"' 2>/dev/null || true)

    if [ "$_ok" = "true" ] && [ -n "$_file_id" ]; then
      _uploaded="yes"
      MANIFEST_FILES="${MANIFEST_FILES}{\"file_id\":\"${_file_id}\",\"message_id\":${_msg_id},\"name\":\"${_fname}\"},"
      FILE_COUNT=$((FILE_COUNT + 1))
      break
    fi

    _retry=$((_retry + 1))
    sleep 3
  done

  if [ -z "$_uploaded" ]; then
    UPLOAD_OK=false
    break
  fi

  sleep 1
done

if [ "$UPLOAD_OK" != "true" ]; then
  echo "❌ فشل الرفع"
  exit 1
fi

MANIFEST_FILES=$(echo "$MANIFEST_FILES" | sed 's/,$//')

# ── 5. مانيفست ──
cat > "$TMP/manifest.json" <<EOF
{
  "id": "$BACKUP_ID",
  "timestamp": "$BACKUP_TS",
  "version": "5",
  "db_size": "$DB_SIZE",
  "files_size": "$FILES_SIZE",
  "file_count": $FILE_COUNT,
  "backup_binary": "$BACKUP_BINARY",
  "reason": "$REASON",
  "files": [$MANIFEST_FILES]
}
EOF

cp "$TMP/manifest.json" "$HIST/${BACKUP_ID}.json"

_manifest_response=$(curl -sS -X POST "${TG}/sendDocument" \
  -F "chat_id=${TG_CHAT_ID}" \
  -F "document=@$TMP/manifest.json;filename=manifest_${BACKUP_ID}.json" \
  -F "caption=📋 #n8n_manifest #n8n_backup
🆔 ${BACKUP_ID}
🕒 ${BACKUP_TS}
📦 ${FILE_COUNT} ملفات
📊 DB: ${DB_SIZE}" 2>/dev/null || true)

_manifest_msg_id=$(echo "$_manifest_response" | jq -r '.result.message_id // empty' 2>/dev/null || true)
if [ -n "$_manifest_msg_id" ]; then
  curl -sS -X POST "${TG}/pinChatMessage" \
    -d "chat_id=${TG_CHAT_ID}" \
    -d "message_id=${_manifest_msg_id}" \
    -d "disable_notification=true" >/dev/null 2>&1 || true
fi

# ── 6. حفظ الحالة ──
_now=$(date +%s)
cat > "$STATE" <<EOF
ID=$BACKUP_ID
TS=$BACKUP_TS
EPOCH=$_now
FORCE_EPOCH=$_now
DB_SIG=$(get_db_signature)
BIN_SIG=$(get_binary_signature)
EOF

# ── 7. تنظيف محلي ──
_local_count=$(ls "$HIST"/*.json 2>/dev/null | wc -l || echo 0)
if [ "$_local_count" -gt 15 ]; then
  ls -t "$HIST"/*.json | tail -n +16 | xargs rm -f 2>/dev/null || true
fi

rm -rf "$TMP"
echo "✅ اكتمل: $BACKUP_ID | $FILE_COUNT ملفات | DB: $DB_SIZE"
exit 0
