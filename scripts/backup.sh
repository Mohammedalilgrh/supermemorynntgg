#!/bin/sh
set -eu
umask 077

: "${TG_BOT_TOKEN:?}"
: "${TG_CHAT_ID:?}"

N8N_DIR="${N8N_DIR:-/home/node/.n8n}"
WORK="${WORK:-/backup-data}"

MIN_INT="${MIN_BACKUP_INTERVAL_SEC:-600}"
FORCE_INT="${FORCE_BACKUP_EVERY_SEC:-21600}"
GZIP_LVL="${GZIP_LEVEL:-1}"
CHUNK_BYTES=18874368

STATE="$WORK/.backup_state"
LOCK="$WORK/.backup_lock"
TMP="$WORK/_bkp_tmp"

TG="https://api.telegram.org/bot${TG_BOT_TOKEN}"

mkdir -p "$WORK"

if ! mkdir "$LOCK" 2>/dev/null; then exit 0; fi
trap 'rmdir "$LOCK" 2>/dev/null; rm -rf "$TMP" 2>/dev/null' EXIT

# ══════════════════════════════════════
# تنظيف عدواني — يمسح التنفيذات فقط
# FIX #3: أضفنا IF EXISTS لكل جدول
# ══════════════════════════════════════
aggressive_clean() {
  [ -s "$N8N_DIR/database.sqlite" ] || return 0
  sqlite3 "$N8N_DIR/database.sqlite" "
    DELETE FROM execution_entity;
    DELETE FROM execution_data WHERE executionId NOT IN (SELECT id FROM execution_entity);
    DROP TABLE IF EXISTS execution_metadata;
    DROP TABLE IF EXISTS workflow_statistics;
    VACUUM;
  " 2>/dev/null || true
}

# FIX #4: db_sig تُحسب بعد التنظيف وليس قبله
db_sig() {
  _s=""
  for _f in database.sqlite; do
    [ -f "$N8N_DIR/$_f" ] && \
      _s="${_s}${_f}:$(stat -c '%s' "$N8N_DIR/$_f" 2>/dev/null || echo 0);"
  done
  printf "%s" "$_s"
}

should_bkp() {
  [ -f "$N8N_DIR/database.sqlite" ] || { echo "NODB"; return; }
  _now=$(date +%s)
  _le=0; _lf=0; _ld=""
  if [ -f "$STATE" ]; then
    _le=$(grep '^LE=' "$STATE" 2>/dev/null | cut -d= -f2 || echo 0)
    _lf=$(grep '^LF=' "$STATE" 2>/dev/null | cut -d= -f2 || echo 0)
    _ld=$(grep '^LD=' "$STATE" 2>/dev/null | cut -d= -f2- || true)
  fi
  [ $((_now - _lf)) -ge "$FORCE_INT" ] && { echo "FORCE"; return; }
  # FIX #4: نظّف أولاً ثم احسب الـ signature
  aggressive_clean
  _cd=$(db_sig)
  [ "$_cd" = "$_ld" ] && { echo "NOCHANGE"; return; }
  [ $((_now - _le)) -lt "$MIN_INT" ] && { echo "COOLDOWN"; return; }
  echo "CHANGED"
}

DEC=$(should_bkp)
case "$DEC" in NODB|NOCHANGE|COOLDOWN) exit 0;; esac

TS_LABEL=$(date +"%Y-%m-%d_%H-%M-%S")
TS_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

echo "┌─────────────────────────────────────┐"
echo "│ 📦 باك أب: $TS_LABEL ($DEC)"
echo "└─────────────────────────────────────┘"

rm -rf "$TMP"; mkdir -p "$TMP/parts"

echo "  🗄️ تصدير الداتابيس..."
sqlite3 "$N8N_DIR/database.sqlite" ".timeout 10000" \
  "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1 || true

sqlite3 "$N8N_DIR/database.sqlite" ".timeout 10000" ".dump" 2>/dev/null \
  | gzip -n -"$GZIP_LVL" -c > "$TMP/db.sql.gz"

[ -s "$TMP/db.sql.gz" ] || { echo "  ❌ فشل التصدير"; exit 1; }
DB_SIZE=$(du -h "$TMP/db.sql.gz" | cut -f1)
echo "  ✅ DB: $DB_SIZE"

_db_bytes=$(stat -c '%s' "$TMP/db.sql.gz" 2>/dev/null || echo 0)
if [ "$_db_bytes" -gt "$CHUNK_BYTES" ]; then
  echo "  ⚠️ كبير — تقسيم..."
  split -b 18M -d -a 3 "$TMP/db.sql.gz" "$TMP/parts/db.sql.gz.part_"
  rm -f "$TMP/db.sql.gz"
  TOTAL_PARTS=$(find "$TMP/parts/" -type f | wc -l | tr -d ' ')
  echo "  ✂️ تم التقسيم لـ $TOTAL_PARTS أجزاء"
else
  mv "$TMP/db.sql.gz" "$TMP/parts/db.sql.gz"
  TOTAL_PARTS=1
fi

echo "  📤 رفع $TOTAL_PARTS ملف..."

FILE_COUNT=0
UPLOAD_OK=true
LAST_MSG_ID=""

# FIX #1: استخدام find بدل ls لتجنب مشاكل المسافات
find "$TMP/parts/" -type f | sort | while read -r _fp; do
  _fn=$(basename "$_fp")
  _fs=$(du -h "$_fp" | cut -f1)

  _caption="📦 #n8n_backup
🆔 ${TS_LABEL}
📄 ${_fn}
📊 جزء $((FILE_COUNT + 1)) من ${TOTAL_PARTS}
💾 ${_fs}"

  _try=0; _ok_flag=""
  while [ "$_try" -lt 3 ]; do
    _resp=$(curl -sS -X POST "${TG}/sendDocument" \
      -F "chat_id=${TG_CHAT_ID}" \
      -F "document=@${_fp};filename=${_fn}" \
      -F "caption=${_caption}" \
      2>/dev/null || true)

    _rok=$(echo "$_resp" | jq -r '.ok // "false"' 2>/dev/null || true)
    _mid=$(echo "$_resp" | jq -r '.result.message_id // empty' 2>/dev/null || true)

    if [ "$_rok" = "true" ] && [ -n "$_mid" ]; then
      _ok_flag="yes"
      FILE_COUNT=$((FILE_COUNT + 1))
      LAST_MSG_ID="$_mid"
      echo "    ✅ $_fn ($_fs)"
      break
    fi

    _try=$((_try + 1))
    sleep 3
  done

  [ -n "$_ok_flag" ] || { UPLOAD_OK=false; break; }
  sleep 1
done

[ "$UPLOAD_OK" = "true" ] || { echo "  ❌ فشل الرفع"; exit 1; }

# لو أكثر من جزء — أرسل رسالة manifest نصية وثبّتها
if [ "$TOTAL_PARTS" -gt 1 ]; then
  _mresp=$(curl -sS -X POST "${TG}/sendMessage" \
    -d "chat_id=${TG_CHAT_ID}" \
    --data-urlencode "text=🗂️ #n8n_manifest
🆔 ${TS_LABEL}
📦 أجزاء: ${TOTAL_PARTS}
💾 الحجم: ${DB_SIZE}" \
    2>/dev/null || true)
  LAST_MSG_ID=$(echo "$_mresp" | jq -r '.result.message_id // empty' 2>/dev/null || true)
fi

if [ -n "$LAST_MSG_ID" ]; then
  curl -sS -X POST "${TG}/pinChatMessage" \
    -d "chat_id=${TG_CHAT_ID}" \
    -d "message_id=${LAST_MSG_ID}" \
    -d "disable_notification=true" >/dev/null 2>&1 || true
  echo "  📌 مثبّت!"
fi

# FIX #4: احفظ الـ signature الحالي بعد التنظيف
cat > "$STATE" <<EOF
ID=$TS_LABEL
TS=$TS_ISO
LE=$(date +%s)
LF=$(date +%s)
LD=$(db_sig)
FC=$FILE_COUNT
SZ=$DB_SIZE
PARTS=$TOTAL_PARTS
EOF

rm -rf "$TMP"
echo "  ✅ اكتمل! DB: $DB_SIZE | أجزاء: $TOTAL_PARTS"
exit 0
