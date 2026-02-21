#!/bin/bash
set -eu
umask 077

: "${TG_BOT_TOKEN:?}"
: "${TG_CHAT_ID:?}"

N8N_DIR="${N8N_DIR:-/home/node/.n8n}"
WORK="${WORK:-/backup-data}"
HIST="$WORK/history"

MIN_INT="${MIN_BACKUP_INTERVAL_SEC:-120}"
FORCE_INT="${FORCE_BACKUP_EVERY_SEC:-1800}"
GZIP_LVL="${GZIP_LEVEL:-6}"
CHUNK="${CHUNK_SIZE:-45M}"

_cn=$(echo "$CHUNK" | tr -d 'MmGgKk')
_cu=$(echo "$CHUNK" | tr -d '0-9' | tr '[:lower:]' '[:upper:]')
case "$_cu" in
  M) CHUNK_BYTES=$((_cn * 1024 * 1024)) ;;
  G) CHUNK_BYTES=$((_cn * 1024 * 1024 * 1024)) ;;
  K) CHUNK_BYTES=$((_cn * 1024)) ;;
  *) CHUNK_BYTES=47185920 ;;
esac

STATE="$WORK/.backup_state"
LOCK="$WORK/.backup_lock"
TMP="$WORK/_bkp_tmp"
TG="https://api.telegram.org/bot${TG_BOT_TOKEN}"

mkdir -p "$WORK" "$HIST"

# ── قفل ──
mkdir "$LOCK" 2>/dev/null || exit 0
trap 'rmdir "$LOCK" 2>/dev/null || true; rm -rf "$TMP" 2>/dev/null || true' EXIT

db_sig() {
  _s=""
  for _f in database.sqlite database.sqlite-wal; do
    [ -f "$N8N_DIR/$_f" ] && \
      _s="${_s}${_f}:$(stat -c '%Y:%s' "$N8N_DIR/$_f" 2>/dev/null || echo 0);"
  done
  printf "%s" "$_s"
}

should_bkp() {
  [ -f "$N8N_DIR/database.sqlite" ] && \
  [ -s "$N8N_DIR/database.sqlite" ] || { echo "NODB"; return; }

  _now=$(date +%s)
  _le=0; _lf=0; _ld=""

  if [ -f "$STATE" ]; then
    _le=$(grep '^LE=' "$STATE" 2>/dev/null | cut -d= -f2 || echo 0)
    _lf=$(grep '^LF=' "$STATE" 2>/dev/null | cut -d= -f2 || echo 0)
    _ld=$(grep '^LD=' "$STATE" 2>/dev/null | cut -d= -f2- || true)
  fi

  _cd=$(db_sig)
  [ $((_now - _lf)) -ge "$FORCE_INT" ] && { echo "FORCE"; return; }
  [ "$_cd" = "$_ld" ] && { echo "NOCHANGE"; return; }
  [ $((_now - _le)) -lt "$MIN_INT" ] && { echo "COOLDOWN"; return; }
  echo "CHANGED"
}

DEC=$(should_bkp)
case "$DEC" in NODB|NOCHANGE|COOLDOWN) exit 0 ;; esac

ID=$(date +"%Y-%m-%d_%H-%M-%S")
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

echo "📦 باك أب: $ID ($DEC)"
rm -rf "$TMP"; mkdir -p "$TMP/parts"

# ── تصدير DB ──
echo "  🗄️ تصدير DB..."
sqlite3 "$N8N_DIR/database.sqlite" \
  "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1 || true

sqlite3 "$N8N_DIR/database.sqlite" \
  ".timeout 15000" ".dump" 2>/dev/null | \
  gzip -"$GZIP_LVL" -c > "$TMP/db.sql.gz"

[ -s "$TMP/db.sql.gz" ] || { echo "❌ فشل"; exit 1; }
DB_SIZE=$(du -h "$TMP/db.sql.gz" | cut -f1)
echo "  ✅ DB: $DB_SIZE"

# ── أرشفة الإعدادات (بدون binaryData) ──
echo "  📁 إعدادات..."
tar -C "$N8N_DIR" \
  --exclude='./database.sqlite' \
  --exclude='./database.sqlite-wal' \
  --exclude='./database.sqlite-shm' \
  --exclude='./binaryData' \
  --exclude='./.cache' \
  --exclude='./logs' \
  -czf "$TMP/files.tar.gz" \
  . 2>/dev/null || true

FILES_SIZE="0"
[ -s "$TMP/files.tar.gz" ] && FILES_SIZE=$(du -h "$TMP/files.tar.gz" | cut -f1)
echo "  ✅ إعدادات: $FILES_SIZE"

# ── تقسيم ──
_db_b=$(stat -c '%s' "$TMP/db.sql.gz" 2>/dev/null || echo 0)
if [ "$_db_b" -gt "$CHUNK_BYTES" ]; then
  split -b "$CHUNK" -d -a 3 "$TMP/db.sql.gz" "$TMP/parts/db.sql.gz.part_"
  rm -f "$TMP/db.sql.gz"
else
  mv "$TMP/db.sql.gz" "$TMP/parts/db.sql.gz"
fi

if [ -s "$TMP/files.tar.gz" ]; then
  _fb=$(stat -c '%s' "$TMP/files.tar.gz" 2>/dev/null || echo 0)
  if [ "$_fb" -gt "$CHUNK_BYTES" ]; then
    split -b "$CHUNK" -d -a 3 "$TMP/files.tar.gz" "$TMP/parts/files.tar.gz.part_"
    rm -f "$TMP/files.tar.gz"
  else
    mv "$TMP/files.tar.gz" "$TMP/parts/files.tar.gz"
  fi
fi

_pcount=$(ls "$TMP/parts/" 2>/dev/null | wc -l)
_total=$(du -sh "$TMP/parts" 2>/dev/null | cut -f1)
echo "  📊 $_pcount ملف | $_total"

# ── رفع ──
echo "  📤 رفع..."
MANIFEST_FILES=""
FILE_COUNT=0

for _fn in $(ls -v "$TMP/parts/"); do
  _fp="$TMP/parts/$_fn"
  [ -f "$_fp" ] || continue
  _fs=$(du -h "$_fp" | cut -f1)
  FILE_COUNT=$((FILE_COUNT + 1))
  echo "  📤 ($FILE_COUNT/$_pcount) $_fn ($_fs)"

  _try=0
  _done=false
  while [ "$_try" -lt 4 ]; do
    _resp=$(curl -sS --max-time 120 -X POST "${TG}/sendDocument" \
      -F "chat_id=${TG_CHAT_ID}" \
      -F "document=@${_fp};filename=${_fn}" \
      -F "caption=🗂 #n8n_backup ${ID} | ${_fn}" \
      2>/dev/null || true)

    _ok=$(echo "$_resp" | jq -r '.ok // "false"' 2>/dev/null || echo "false")
    _fid=$(echo "$_resp" | jq -r '.result.document.file_id // empty' 2>/dev/null || true)
    _mid=$(echo "$_resp" | jq -r '.result.message_id // empty' 2>/dev/null || true)

    if [ "$_ok" = "true" ] && [ -n "$_fid" ]; then
      MANIFEST_FILES="${MANIFEST_FILES}{\"msg_id\":${_mid},\"file_id\":\"${_fid}\",\"name\":\"${_fn}\"},"
      _done=true
      echo "    ✅"
      break
    fi
    _try=$((_try + 1))
    echo "    ⚠️ $_try/4"
    sleep $((_try * 4))
  done

  [ "$_done" = "true" ] || { echo "❌ فشل"; exit 1; }
  sleep 2
done

# ── مانيفست ──
MANIFEST_FILES="${MANIFEST_FILES%,}"

printf '{
  "id":"%s",
  "timestamp":"%s",
  "type":"n8n-telegram-backup",
  "version":"6.0",
  "db_size":"%s",
  "files_size":"%s",
  "file_count":%s,
  "binary_data":"false",
  "files":[%s]
}\n' "$ID" "$TS" "$DB_SIZE" "$FILES_SIZE" "$FILE_COUNT" "$MANIFEST_FILES" \
  > "$TMP/manifest.json"

cp "$TMP/manifest.json" "$HIST/${ID}.json"

_mr=$(curl -sS --max-time 60 -X POST "${TG}/sendDocument" \
  -F "chat_id=${TG_CHAT_ID}" \
  -F "document=@$TMP/manifest.json;filename=manifest_${ID}.json" \
  -F "caption=📋 #n8n_manifest #n8n_backup
🆔 ${ID}
🕒 ${TS}
📦 ${FILE_COUNT} ملفات | DB: ${DB_SIZE}" \
  2>/dev/null || true)

_mmid=$(echo "$_mr" | jq -r '.result.message_id // empty' 2>/dev/null || true)
_mok=$(echo "$_mr" | jq -r '.ok // "false"' 2>/dev/null || echo "false")

if [ "$_mok" = "true" ] && [ -n "$_mmid" ]; then
  curl -sS --max-time 15 -X POST "${TG}/pinChatMessage" \
    -d "chat_id=${TG_CHAT_ID}" \
    -d "message_id=${_mmid}" \
    -d "disable_notification=true" >/dev/null 2>&1 || true
  echo "  ✅ مانيفست مثبّت"
fi

_ts=$(date +%s)
printf 'ID=%s\nTS=%s\nLE=%s\nLF=%s\nLD=%s\n' \
  "$ID" "$TS" "$_ts" "$_ts" "$(db_sig)" > "$STATE"

# تنظيف
ls -t "$HIST"/*.json 2>/dev/null | tail -n +21 | \
  xargs rm -f 2>/dev/null || true

rm -rf "$TMP"
echo "✅ اكتمل! $ID | $FILE_COUNT ملفات | DB: $DB_SIZE"
exit 0
