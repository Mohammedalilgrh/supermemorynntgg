#!/bin/sh
set -eu
umask 077

: "${TG_BOT_TOKEN:?}"
: "${TG_CHAT_ID:?}"

N8N_DIR="${N8N_DIR:-/home/node/.n8n}"
WORK="${WORK:-/backup-data}"
HIST="$WORK/history"

MIN_INT="${MIN_BACKUP_INTERVAL_SEC:-60}"
FORCE_INT="${FORCE_BACKUP_EVERY_SEC:-900}"
BKP_BIN="${BACKUP_BINARYDATA:-true}"
GZIP_LVL="${GZIP_LEVEL:-1}"
CHUNK="${CHUNK_SIZE:-18M}"
CHUNK_BYTES=18874368

STATE="$WORK/.backup_state"
LOCK="$WORK/.backup_lock"
TMP="$WORK/_bkp_tmp"

TG="https://api.telegram.org/bot${TG_BOT_TOKEN}"

mkdir -p "$WORK" "$HIST"

if ! mkdir "$LOCK" 2>/dev/null; then exit 0; fi
trap 'rmdir "$LOCK" 2>/dev/null; rm -rf "$TMP" 2>/dev/null' EXIT

db_sig() {
  _s=""
  for _f in database.sqlite database.sqlite-wal database.sqlite-shm; do
    [ -f "$N8N_DIR/$_f" ] && \
      _s="${_s}${_f}:$(stat -c '%Y:%s' "$N8N_DIR/$_f" 2>/dev/null || echo 0);"
  done
  printf "%s" "$_s"
}

bin_sig() {
  [ "$BKP_BIN" = "true" ] || { printf "skip"; return; }
  [ -d "$N8N_DIR/binaryData" ] || { printf "none"; return; }
  du -sk "$N8N_DIR/binaryData" 2>/dev/null | awk '{print $1}'
}

should_bkp() {
  [ -f "$N8N_DIR/database.sqlite" ] || { echo "NODB"; return; }
  _now=$(date +%s)
  _le=0; _lf=0; _ld=""; _lb=""
  if [ -f "$STATE" ]; then
    _le=$(grep '^LE=' "$STATE" 2>/dev/null | cut -d= -f2 || echo 0)
    _lf=$(grep '^LF=' "$STATE" 2>/dev/null | cut -d= -f2 || echo 0)
    _ld=$(grep '^LD=' "$STATE" 2>/dev/null | cut -d= -f2- || true)
    _lb=$(grep '^LB=' "$STATE" 2>/dev/null | cut -d= -f2- || true)
  fi
  _cd=$(db_sig); _cb=$(bin_sig)
  [ $((_now - _lf)) -ge "$FORCE_INT" ] && { echo "FORCE"; return; }
  [ "$_cd" = "$_ld" ] && [ "$_cb" = "$_lb" ] && { echo "NOCHANGE"; return; }
  [ $((_now - _le)) -lt "$MIN_INT" ] && { echo "COOLDOWN"; return; }
  echo "CHANGED"
}

DEC=$(should_bkp)
case "$DEC" in NODB|NOCHANGE|COOLDOWN) exit 0;; esac

ID=$(date +"%Y-%m-%d_%H-%M-%S")
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

echo "┌─────────────────────────────────────┐"
echo "│ 📦 باك أب: $ID ($DEC)"
echo "└─────────────────────────────────────┘"

rm -rf "$TMP"; mkdir -p "$TMP/parts"

echo "  🗄️ تصدير الداتابيس..."
sqlite3 "$N8N_DIR/database.sqlite" ".timeout 10000" "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1 || true
sqlite3 "$N8N_DIR/database.sqlite" ".timeout 10000" ".dump" 2>/dev/null | gzip -n -"$GZIP_LVL" -c > "$TMP/db.sql.gz"

[ -s "$TMP/db.sql.gz" ] || { echo "  ❌ فشل"; exit 1; }
DB_SIZE=$(du -h "$TMP/db.sql.gz" | cut -f1)
echo "  ✅ DB: $DB_SIZE"

echo "  📁 أرشفة الملفات..."
_exc="--exclude=database.sqlite --exclude=database.sqlite-wal --exclude=database.sqlite-shm"
[ "$BKP_BIN" != "true" ] && _exc="$_exc --exclude=binaryData"

tar -C "$N8N_DIR" -cf - $_exc . 2>/dev/null | gzip -n -"$GZIP_LVL" -c > "$TMP/files.tar.gz" || true

FILES_SIZE="0"
[ -s "$TMP/files.tar.gz" ] && FILES_SIZE=$(du -h "$TMP/files.tar.gz" | cut -f1)

echo "  ✂️ تجهيز..."
_db_bytes=$(stat -c '%s' "$TMP/db.sql.gz" 2>/dev/null || echo 0)
if [ "$_db_bytes" -gt "$CHUNK_BYTES" ]; then
  split -b "$CHUNK" -d -a 3 "$TMP/db.sql.gz" "$TMP/parts/db.sql.gz.part_"
  rm -f "$TMP/db.sql.gz"
else
  mv "$TMP/db.sql.gz" "$TMP/parts/db.sql.gz"
fi

if [ -s "$TMP/files.tar.gz" ]; then
  _f_bytes=$(stat -c '%s' "$TMP/files.tar.gz" 2>/dev/null || echo 0)
  if [ "$_f_bytes" -gt "$CHUNK_BYTES" ]; then
    split -b "$CHUNK" -d -a 3 "$TMP/files.tar.gz" "$TMP/parts/files.tar.gz.part_"
    rm -f "$TMP/files.tar.gz"
  else
    mv "$TMP/files.tar.gz" "$TMP/parts/files.tar.gz"
  fi
fi

echo "  📤 رفع إلى Telegram..."
MANIFEST_FILES=""
FILE_COUNT=0
UPLOAD_OK=true

for f in "$TMP/parts"/*; do
  [ -f "$f" ] || continue
  _fn=$(basename "$f")
  _fs=$(du -h "$f" | cut -f1)

  _try=0; _result=""
  while [ "$_try" -lt 3 ]; do
    _resp=$(curl -sS -X POST "${TG}/sendDocument" \
      -F "chat_id=${TG_CHAT_ID}" \
      -F "document=@${f}" \
      -F "caption=🗂 #n8n_backup ${ID} | ${_fn}" \
      -F "parse_mode=HTML" 2>/dev/null || true)

    _fid=$(echo "$_resp" | jq -r '.result.document.file_id // empty' 2>/dev/null || true)
    _mid=$(echo "$_resp" | jq -r '.result.message_id // empty' 2>/dev/null || true)
    _ok=$(echo "$_resp" | jq -r '.ok // "false"' 2>/dev/null || true)

    if [ "$_ok" = "true" ] && [ -n "$_fid" ]; then
      _result="ok"
      MANIFEST_FILES="${MANIFEST_FILES}{\"msg_id\":${_mid},\"file_id\":\"${_fid}\",\"name\":\"${_fn}\"},"
      FILE_COUNT=$((FILE_COUNT + 1))
      echo "    ✅ $_fn ($_fs)"
      break
    fi
    _try=$((_try + 1))
    echo "    ⚠️ إعادة $_try/3..."
    sleep 3
  done

  [ -n "$_result" ] || { UPLOAD_OK=false; break; }
  sleep 1
done

[ "$UPLOAD_OK" = "true" ] || { echo "  ❌ فشل الرفع"; exit 1; }

MANIFEST_FILES=$(echo "$MANIFEST_FILES" | sed 's/,$//')

cat > "$TMP/manifest.json" <<EOF
{
  "id": "$ID",
  "timestamp": "$TS",
  "type": "n8n-telegram-backup",
  "version": "4.0",
  "db_size": "$DB_SIZE",
  "files_size": "$FILES_SIZE",
  "file_count": $FILE_COUNT,
  "binary_data": "$BKP_BIN",
  "files": [${MANIFEST_FILES}]
}
EOF

cp "$TMP/manifest.json" "$HIST/${ID}.json"

echo "  📋 إرسال المانيفست..."
_man_resp=$(curl -sS -X POST "${TG}/sendDocument" \
  -F "chat_id=${TG_CHAT_ID}" \
  -F "document=@$TMP/manifest.json;filename=manifest_${ID}.json" \
  -F "caption=📋 #n8n_manifest #n8n_backup
🆔 ${ID}
🕒 ${TS}
📦 ${FILE_COUNT} ملفات
📊 DB: ${DB_SIZE}" \
  -F "parse_mode=HTML" 2>/dev/null || true)

_man_mid=$(echo "$_man_resp" | jq -r '.result.message_id // empty' 2>/dev/null || true)

if [ -n "$_man_mid" ]; then
  curl -sS -X POST "${TG}/pinChatMessage" \
    -d "chat_id=${TG_CHAT_ID}" \
    -d "message_id=${_man_mid}" \
    -d "disable_notification=true" >/dev/null 2>&1 || true
  echo "  ✅ المانيفست مثبّت"
fi

cat > "$STATE" <<EOF
ID=$ID
TS=$TS
LE=$(date +%s)
LF=$(date +%s)
LD=$(db_sig)
LB=$(bin_sig)
EOF

_hist_count=$(ls "$HIST"/*.json 2>/dev/null | wc -l || echo 0)
if [ "$_hist_count" -gt 20 ]; then
  for _old in $(ls -t "$HIST"/*.json | tail -n +21); do
    rm -f "$_old"
  done
fi

rm -rf "$TMP"
echo "┌─────────────────────────────────────┐"
echo "│ ✅ اكتمل! $ID                       │"
echo "│ 📦 $FILE_COUNT ملفات | DB: $DB_SIZE │"
echo "└─────────────────────────────────────┘"
exit 0
