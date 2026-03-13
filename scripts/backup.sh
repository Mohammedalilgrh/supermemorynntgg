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
CHUNK="${CHUNK_SIZE:-18M}"
CHUNK_BYTES=18874368

STATE="$WORK/.backup_state"
LOCK="$WORK/.backup_lock"
TMP="$WORK/_bkp_tmp"

TG="https://api.telegram.org/bot${TG_BOT_TOKEN}"

mkdir -p "$WORK"

# ── القفل ──
if ! mkdir "$LOCK" 2>/dev/null; then exit 0; fi
trap 'rmdir "$LOCK" 2>/dev/null; rm -rf "$TMP" 2>/dev/null' EXIT

# ══════════════════════════════════════
# ⭐ تنظيف عدواني للـ DB قبل أي شيء
# نحذف كل شيء ما عدا: workflows, credentials, settings
# ══════════════════════════════════════
aggressive_clean() {
  [ -s "$N8N_DIR/database.sqlite" ] || return 0
  
  sqlite3 "$N8N_DIR/database.sqlite" "
    DELETE FROM execution_entity;
    DELETE FROM execution_data;
    DELETE FROM execution_metadata;
    DELETE FROM workflow_statistics;
    VACUUM;
  " 2>/dev/null || true
}

# ── كشف التغيير ──
db_sig() {
  _s=""
  for _f in database.sqlite database.sqlite-wal database.sqlite-shm; do
    [ -f "$N8N_DIR/$_f" ] && \
      _s="${_s}${_f}:$(stat -c '%Y:%s' "$N8N_DIR/$_f" 2>/dev/null || echo 0);"
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
  _cd=$(db_sig)
  [ $((_now - _lf)) -ge "$FORCE_INT" ] && { echo "FORCE"; return; }
  [ "$_cd" = "$_ld" ] && { echo "NOCHANGE"; return; }
  [ $((_now - _le)) -lt "$MIN_INT" ] && { echo "COOLDOWN"; return; }
  echo "CHANGED"
}

DEC=$(should_bkp)
case "$DEC" in NODB|NOCHANGE|COOLDOWN) exit 0;; esac

# ── تنظيف قبل الباك أب ──
echo "  🧹 تنظيف DB قبل الباك أب..."
aggressive_clean

TS_LABEL=$(date +"%Y-%m-%d_%H-%M-%S")
TS_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

echo "┌─────────────────────────────────────┐"
echo "│ 📦 باك أب: $TS_LABEL ($DEC)"
echo "└─────────────────────────────────────┘"

rm -rf "$TMP"; mkdir -p "$TMP/parts"

# ── تصدير DB ──
echo "  🗄️ تصدير الداتابيس..."
sqlite3 "$N8N_DIR/database.sqlite" ".timeout 10000" \
  "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1 || true

sqlite3 "$N8N_DIR/database.sqlite" ".timeout 10000" ".dump" 2>/dev/null \
  | gzip -n -"$GZIP_LVL" -c > "$TMP/db.sql.gz"

[ -s "$TMP/db.sql.gz" ] || { echo "  ❌ فشل التصدير"; exit 1; }
DB_SIZE=$(du -h "$TMP/db.sql.gz" | cut -f1)
echo "  ✅ DB: $DB_SIZE"

# ── تحقق من الحجم — لو أكبر من 18MB في مشكلة ──
_db_bytes=$(stat -c '%s' "$TMP/db.sql.gz" 2>/dev/null || echo 0)
if [ "$_db_bytes" -gt "$CHUNK_BYTES" ]; then
  echo "  ⚠️ الملف كبير جداً ($_db_bytes bytes) — تقسيم..."
  split -b "$CHUNK" -d -a 3 "$TMP/db.sql.gz" "$TMP/parts/db.sql.gz.part_"
  rm -f "$TMP/db.sql.gz"
  TOTAL_PARTS=$(ls "$TMP/parts/" | wc -l | tr -d ' ')
  echo "  ✂️ تم التقسيم لـ $TOTAL_PARTS أجزاء"
else
  mv "$TMP/db.sql.gz" "$TMP/parts/db.sql.gz"
  TOTAL_PARTS=1
fi

# ── رفع لـ Telegram ──
echo "  📤 رفع $TOTAL_PARTS ملف..."

FILE_COUNT=0
UPLOAD_OK=true
LAST_MSG_ID=""
ALL_FILE_IDS=""

for f in $(ls "$TMP/parts/" | sort); do
  _fp="$TMP/parts/$f"
  [ -f "$_fp" ] || continue
  _fn=$(basename "$_fp")
  _fs=$(du -h "$_fp" | cut -f1)

  # ⭐ نضيف BACKUP_ID و TOTAL_PARTS في الكابشن
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
    _fid=$(echo "$_resp" | jq -r '.result.document.file_id // empty' 2>/dev/null || true)

    if [ "$_rok" = "true" ] && [ -n "$_mid" ]; then
      _ok_flag="yes"
      FILE_COUNT=$((FILE_COUNT + 1))
      LAST_MSG_ID="$_mid"
      ALL_FILE_IDS="${ALL_FILE_IDS}${_fid}:${_fn}|"
      echo "    ✅ $_fn ($_fs) msg_id=$_mid"
      break
    fi

    _try=$((_try + 1))
    sleep 3
  done

  [ -n "$_ok_flag" ] || { UPLOAD_OK=false; break; }
  sleep 1
done

[ "$UPLOAD_OK" = "true" ] || { echo "  ❌ فشل الرفع"; exit 1; }

# ── إرسال رسالة manifest لو في أكثر من جزء ──
if [ "$TOTAL_PARTS" -gt 1 ]; then
  echo "  📋 إرسال manifest..."
  _manifest_msg="🗂️ #n8n_manifest
🆔 ${TS_LABEL}
📦 أجزاء: ${TOTAL_PARTS}
💾 الحجم: ${DB_SIZE}
📌 أرجع للرسائل فوق لتحميل الأجزاء"

  _mresp=$(curl -sS -X POST "${TG}/sendMessage" \
    -d "chat_id=${TG_CHAT_ID}" \
    -d "text=${_manifest_msg}" \
    2>/dev/null || true)
  LAST_MSG_ID=$(echo "$_mresp" | jq -r '.result.message_id // empty' 2>/dev/null || true)
fi

# ── تثبيت آخر رسالة ──
if [ -n "$LAST_MSG_ID" ]; then
  curl -sS -X POST "${TG}/pinChatMessage" \
    -d "chat_id=${TG_CHAT_ID}" \
    -d "message_id=${LAST_MSG_ID}" \
    -d "disable_notification=true" >/dev/null 2>&1 || true
  echo "  📌 مثبّت! (msg_id=$LAST_MSG_ID)"
fi

# ── حفظ الحالة ──
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
