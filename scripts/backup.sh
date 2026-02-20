#!/bin/sh
set -eu
umask 077

: "${TG_BOT_TOKEN:?}"
: "${TG_CHAT_ID:?}"

N8N_DIR="${N8N_DIR:-/home/node/.n8n}"
WORK="${WORK:-/backup-data}"
HIST="$WORK/history"

MIN_INT="${MIN_BACKUP_INTERVAL_SEC:-120}"
FORCE_INT="${FORCE_BACKUP_EVERY_SEC:-1800}"
BKP_BIN="${BACKUP_BINARYDATA:-false}"
GZIP_LVL="${GZIP_LEVEL:-6}"
CHUNK="${CHUNK_SIZE:-45M}"

# حساب bytes من CHUNK
_chunk_num=$(echo "$CHUNK" | tr -d 'MmGgKk')
_chunk_unit=$(echo "$CHUNK" | tr -d '0-9')
case "$_chunk_unit" in
  M|m) CHUNK_BYTES=$((_chunk_num * 1024 * 1024)) ;;
  G|g) CHUNK_BYTES=$((_chunk_num * 1024 * 1024 * 1024)) ;;
  K|k) CHUNK_BYTES=$((_chunk_num * 1024)) ;;
  *)   CHUNK_BYTES=47185920 ;;
esac

STATE="$WORK/.backup_state"
LOCK="$WORK/.backup_lock"
TMP="$WORK/_bkp_tmp"
TG="https://api.telegram.org/bot${TG_BOT_TOKEN}"

mkdir -p "$WORK" "$HIST"

# ── القفل لمنع التشغيل المزدوج ──
if ! mkdir "$LOCK" 2>/dev/null; then
  exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null || true; rm -rf "$TMP" 2>/dev/null || true' EXIT

# ── حساب حجم DB ──
db_size_bytes() {
  _f="$N8N_DIR/database.sqlite"
  [ -f "$_f" ] && stat -c '%s' "$_f" 2>/dev/null || echo 0
}

# ── توقيع التغيير ──
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
  find "$N8N_DIR/binaryData" -type f 2>/dev/null | wc -l | tr -d ' '
}

# ── هل يجب عمل باك أب؟ ──
should_bkp() {
  [ -f "$N8N_DIR/database.sqlite" ] || { echo "NODB"; return; }
  [ -s "$N8N_DIR/database.sqlite" ] || { echo "NODB"; return; }

  _now=$(date +%s)
  _le=0; _lf=0; _ld=""; _lb=""

  if [ -f "$STATE" ]; then
    _le=$(grep '^LE=' "$STATE" 2>/dev/null | cut -d= -f2 || echo 0)
    _lf=$(grep '^LF=' "$STATE" 2>/dev/null | cut -d= -f2 || echo 0)
    _ld=$(grep '^LD=' "$STATE" 2>/dev/null | cut -d= -f2- || true)
    _lb=$(grep '^LB=' "$STATE" 2>/dev/null | cut -d= -f2- || true)
  fi

  _cd=$(db_sig)
  _cb=$(bin_sig)

  [ $((_now - _lf)) -ge "$FORCE_INT" ] && { echo "FORCE"; return; }
  [ "$_cd" = "$_ld" ] && [ "$_cb" = "$_lb" ] && { echo "NOCHANGE"; return; }
  [ $((_now - _le)) -lt "$MIN_INT" ] && { echo "COOLDOWN"; return; }
  echo "CHANGED"
}

DEC=$(should_bkp)
case "$DEC" in
  NODB|NOCHANGE|COOLDOWN) exit 0 ;;
esac

ID=$(date +"%Y-%m-%d_%H-%M-%S")
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

echo "┌──────────────────────────────────────┐"
echo "│ 📦 باك أب: $ID ($DEC)"
echo "└──────────────────────────────────────┘"

rm -rf "$TMP"
mkdir -p "$TMP/parts"

# ── تصدير DB بشكل آمن ──
echo "  🗄️ تصدير قاعدة البيانات..."

# WAL checkpoint أولاً
sqlite3 "$N8N_DIR/database.sqlite" \
  "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1 || true

# تصدير SQL dump
if ! sqlite3 "$N8N_DIR/database.sqlite" \
  ".timeout 15000" \
  ".dump" 2>/dev/null | \
  gzip -"$GZIP_LVL" -c > "$TMP/db.sql.gz"; then
  echo "  ❌ فشل تصدير DB"
  exit 1
fi

[ -s "$TMP/db.sql.gz" ] || { echo "  ❌ DB فارغة بعد الضغط"; exit 1; }

DB_SIZE=$(du -h "$TMP/db.sql.gz" | cut -f1)
echo "  ✅ DB: $DB_SIZE"

# ── أرشفة الملفات (بدون DB) ──
echo "  📁 أرشفة إعدادات n8n..."

_tar_args="-C $N8N_DIR"
_excludes="--exclude=./database.sqlite --exclude=./database.sqlite-wal --exclude=./database.sqlite-shm --exclude=./.cache --exclude=./binaryData"

if [ "$BKP_BIN" = "true" ]; then
  _excludes="--exclude=./database.sqlite --exclude=./database.sqlite-wal --exclude=./database.sqlite-shm --exclude=./.cache"
fi

# إنشاء tar بدون أخطاء
eval "tar $_tar_args -cf - $_excludes . 2>/dev/null" | \
  gzip -"$GZIP_LVL" -c > "$TMP/files.tar.gz" || true

FILES_SIZE="0"
if [ -s "$TMP/files.tar.gz" ]; then
  FILES_SIZE=$(du -h "$TMP/files.tar.gz" | cut -f1)
  echo "  ✅ الملفات: $FILES_SIZE"
fi

# ── تقسيم الملفات الكبيرة ──
echo "  ✂️ تجهيز الأجزاء..."

# تقسيم DB
_db_bytes=$(stat -c '%s' "$TMP/db.sql.gz" 2>/dev/null || echo 0)
if [ "$_db_bytes" -gt "$CHUNK_BYTES" ]; then
  split -b "$CHUNK" -d -a 3 "$TMP/db.sql.gz" "$TMP/parts/db.sql.gz.part_"
  rm -f "$TMP/db.sql.gz"
  echo "  ✂️ DB مقسّمة: $(ls "$TMP/parts"/db.sql.gz.part_* 2>/dev/null | wc -l) أجزاء"
else
  mv "$TMP/db.sql.gz" "$TMP/parts/db.sql.gz"
fi

# تقسيم الملفات
if [ -s "$TMP/files.tar.gz" ]; then
  _f_bytes=$(stat -c '%s' "$TMP/files.tar.gz" 2>/dev/null || echo 0)
  if [ "$_f_bytes" -gt "$CHUNK_BYTES" ]; then
    split -b "$CHUNK" -d -a 3 "$TMP/files.tar.gz" "$TMP/parts/files.tar.gz.part_"
    rm -f "$TMP/files.tar.gz"
  else
    mv "$TMP/files.tar.gz" "$TMP/parts/files.tar.gz"
  fi
fi

# ── رفع إلى Telegram ──
echo "  📤 رفع إلى Telegram..."

MANIFEST_FILES=""
FILE_COUNT=0
UPLOAD_OK=true
TOTAL_PARTS=$(ls "$TMP/parts"/ | wc -l)

for f in $(ls -v "$TMP/parts"/); do
  _fp="$TMP/parts/$f"
  [ -f "$_fp" ] || continue
  _fn="$f"
  _fs=$(du -h "$_fp" | cut -f1)
  FILE_COUNT=$((FILE_COUNT + 1))

  echo "  📤 ($FILE_COUNT/$TOTAL_PARTS) $_fn ($_fs)..."

  _try=0
  _result=""
  while [ "$_try" -lt 4 ]; do
    _resp=$(curl -sS --max-time 120 -X POST "${TG}/sendDocument" \
      -F "chat_id=${TG_CHAT_ID}" \
      -F "document=@${_fp};filename=${_fn}" \
      -F "caption=🗂 #n8n_backup ${ID} | ${_fn} (${FILE_COUNT}/${TOTAL_PARTS})" \
      2>/dev/null || true)

    _ok=$(echo "$_resp" | jq -r '.ok // "false"' 2>/dev/null || echo "false")
    _fid=$(echo "$_resp" | jq -r '.result.document.file_id // empty' 2>/dev/null || true)
    _mid=$(echo "$_resp" | jq -r '.result.message_id // empty' 2>/dev/null || true)

    if [ "$_ok" = "true" ] && [ -n "$_fid" ]; then
      _result="ok"
      MANIFEST_FILES="${MANIFEST_FILES}{\"msg_id\":${_mid},\"file_id\":\"${_fid}\",\"name\":\"${_fn}\"},"
      echo "    ✅ تم رفع $_fn"
      break
    fi

    _err=$(echo "$_resp" | jq -r '.description // "unknown"' 2>/dev/null || echo "unknown")
    _try=$((_try + 1))
    echo "    ⚠️ إعادة $_try/4 - $_err"
    sleep $((_try * 3))
  done

  if [ -z "$_result" ]; then
    UPLOAD_OK=false
    echo "  ❌ فشل رفع $_fn"
    break
  fi

  # تأخير بين الملفات لتجنب rate limiting
  sleep 2
done

if [ "$UPLOAD_OK" = "false" ]; then
  echo "  ❌ فشل الرفع"
  exit 1
fi

# ── إنشاء المانيفست ──
MANIFEST_FILES=$(echo "$MANIFEST_FILES" | sed 's/,$//')

_manifest_content="{
  \"id\": \"${ID}\",
  \"timestamp\": \"${TS}\",
  \"type\": \"n8n-telegram-backup\",
  \"version\": \"5.0\",
  \"db_size\": \"${DB_SIZE}\",
  \"files_size\": \"${FILES_SIZE}\",
  \"file_count\": ${FILE_COUNT},
  \"binary_data\": \"${BKP_BIN}\",
  \"files\": [${MANIFEST_FILES}]
}"

echo "$_manifest_content" > "$TMP/manifest.json"

# حفظ محلي
cp "$TMP/manifest.json" "$HIST/${ID}.json"

# ── رفع المانيفست والتثبيت ──
echo "  📋 رفع المانيفست..."

_cap="📋 #n8n_manifest #n8n_backup
🆔 ${ID}
🕒 ${TS}
📦 ${FILE_COUNT} ملفات | DB: ${DB_SIZE}"

_man_resp=$(curl -sS --max-time 60 -X POST "${TG}/sendDocument" \
  -F "chat_id=${TG_CHAT_ID}" \
  -F "document=@$TMP/manifest.json;filename=manifest_${ID}.json" \
  -F "caption=${_cap}" \
  2>/dev/null || true)

_man_mid=$(echo "$_man_resp" | jq -r '.result.message_id // empty' 2>/dev/null || true)
_man_ok=$(echo "$_man_resp" | jq -r '.ok // "false"' 2>/dev/null || echo "false")

if [ "$_man_ok" = "true" ] && [ -n "$_man_mid" ]; then
  # تثبيت المانيفست
  curl -sS --max-time 15 -X POST "${TG}/pinChatMessage" \
    -d "chat_id=${TG_CHAT_ID}" \
    -d "message_id=${_man_mid}" \
    -d "disable_notification=true" \
    >/dev/null 2>&1 || true
  echo "  ✅ المانيفست مثبّت (ID: $_man_mid)"
else
  echo "  ⚠️ تحذير: فشل رفع المانيفست"
fi

# ── حفظ الحالة ──
_now_ts=$(date +%s)
printf "ID=%s\nTS=%s\nLE=%s\nLF=%s\nLD=%s\nLB=%s\n" \
  "$ID" "$TS" "$_now_ts" "$_now_ts" "$(db_sig)" "$(bin_sig)" \
  > "$STATE"

# ── تنظيف السجل المحلي (نحتفظ بآخر 20) ──
_hist_list=$(ls -t "$HIST"/*.json 2>/dev/null || true)
_hist_count=$(echo "$_hist_list" | grep -c '\.json$' || echo 0)
if [ "$_hist_count" -gt 20 ]; then
  echo "$_hist_list" | tail -n +21 | while read -r _old; do
    rm -f "$_old" || true
  done
fi

rm -rf "$TMP"

echo ""
echo "┌──────────────────────────────────────┐"
echo "│ ✅ اكتمل الباك أب!"
echo "│ 🆔 $ID"
echo "│ 📦 $FILE_COUNT ملفات | DB: $DB_SIZE"
echo "└──────────────────────────────────────┘"
exit 0
