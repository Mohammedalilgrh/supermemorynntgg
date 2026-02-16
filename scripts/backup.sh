#!/bin/sh
set -eu
umask 077

: "${TG_BOT_TOKEN:?}"
: "${TG_CHAT_ID:?}"

N8N_DIR="${N8N_DIR:-/home/node/.n8n}"
WORK="${WORK:-/backup-data}"

MIN_INT="${MIN_BACKUP_INTERVAL_SEC:-60}"
FORCE_INT="${FORCE_BACKUP_EVERY_SEC:-900}"
BKP_BIN="${BACKUP_BINARYDATA:-true}"
GZIP_LVL="${GZIP_LEVEL:-1}"

# Telegram API limits: max 50MB per file via bot API
# لكن نقسمها 45MB للأمان
CHUNK_SIZE="${CHUNK_SIZE:-45M}"

STATE="$WORK/.backup_state"
LOCK="$WORK/.backup_lock"
TMP="$WORK/_backup_tmp"

TG_API="https://api.telegram.org/bot${TG_BOT_TOKEN}"

mkdir -p "$WORK"

# ── القفل ──
if ! mkdir "$LOCK" 2>/dev/null; then
  exit 0
fi
trap 'rmdir "$LOCK" 2>/dev/null; rm -rf "$TMP" 2>/dev/null' EXIT

# ── دوال Telegram ──

tg_send_msg() {
  curl -sS -X POST "${TG_API}/sendMessage" \
    -d "chat_id=${TG_CHAT_ID}" \
    -d "parse_mode=HTML" \
    -d "text=$1" >/dev/null 2>&1 || true
}

tg_send_file() {
  _file="$1"
  _caption="${2:-}"
  _fname=$(basename "$_file")

  _resp=$(curl -sS -X POST "${TG_API}/sendDocument" \
    -F "chat_id=${TG_CHAT_ID}" \
    -F "document=@${_file}" \
    -F "caption=${_caption}" \
    -F "parse_mode=HTML")

  # استخرج file_id و message_id
  _file_id=$(echo "$_resp" | jq -r '.result.document.file_id // empty' 2>/dev/null || true)
  _msg_id=$(echo "$_resp" | jq -r '.result.message_id // empty' 2>/dev/null || true)
  _ok=$(echo "$_resp" | jq -r '.ok // "false"' 2>/dev/null || true)

  if [ "$_ok" = "true" ] && [ -n "$_file_id" ]; then
    echo "${_msg_id}|${_file_id}|${_fname}"
    return 0
  else
    echo ""
    return 1
  fi
}

tg_pin_msg() {
  curl -sS -X POST "${TG_API}/pinChatMessage" \
    -d "chat_id=${TG_CHAT_ID}" \
    -d "message_id=$1" \
    -d "disable_notification=true" >/dev/null 2>&1 || true
}

# ── كشف التغييرات ──

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

save_state() {
  cat > "$STATE" <<EOF
ID=$1
TS=$2
LE=$(date +%s)
LF=$(date +%s)
LD=$(db_sig)
LB=$(bin_sig)
EOF
}

# ══════════════════════════════════
# البداية
# ══════════════════════════════════

DEC=$(should_bkp)
case "$DEC" in
  NODB|NOCHANGE|COOLDOWN) exit 0 ;;
esac

ID=$(date +"%Y-%m-%d_%H-%M-%S")
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

echo ""
echo "┌─────────────────────────────────────┐"
echo "│ 📦 باك أب: $ID"
echo "│ 📝 السبب: $DEC"
echo "└─────────────────────────────────────┘"

rm -rf "$TMP"; mkdir -p "$TMP/parts"

# ── 1. تصدير قاعدة البيانات ──
echo "  🗄️  تصدير الداتابيس..."

sqlite3 "$N8N_DIR/database.sqlite" ".timeout 10000" \
  "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1 || true

sqlite3 "$N8N_DIR/database.sqlite" ".timeout 10000" ".dump" \
  2>/dev/null \
  | gzip -n -"$GZIP_LVL" -c \
  > "$TMP/db.sql.gz"

if [ ! -s "$TMP/db.sql.gz" ]; then
  echo "  ❌ فشل تصدير الداتابيس"
  exit 1
fi

DB_SIZE=$(du -h "$TMP/db.sql.gz" | cut -f1)
echo "  ✅ حجم الداتابيس: $DB_SIZE"

# ── 2. أرشيف الملفات ──
echo "  📁 أرشفة الملفات..."

_exc="--exclude=database.sqlite --exclude=database.sqlite-wal --exclude=database.sqlite-shm"
[ "$BKP_BIN" != "true" ] && _exc="$_exc --exclude=binaryData"

tar -C "$N8N_DIR" -cf - $_exc . 2>/dev/null \
  | gzip -n -"$GZIP_LVL" -c \
  > "$TMP/files.tar.gz" || true

if [ -s "$TMP/files.tar.gz" ]; then
  FILES_SIZE=$(du -h "$TMP/files.tar.gz" | cut -f1)
  echo "  ✅ حجم الملفات: $FILES_SIZE"
else
  echo "  ℹ️  لا ملفات إضافية"
  rm -f "$TMP/files.tar.gz"
fi

# ── 3. ملف المعلومات ──
cat > "$TMP/backup_info.json" <<EOF
{
  "id": "$ID",
  "timestamp": "$TS",
  "type": "n8n-telegram-backup",
  "version": "3.0",
  "db_size": "$DB_SIZE",
  "files_size": "${FILES_SIZE:-0}",
  "binary_data": "$BKP_BIN",
  "tag": "#n8n_backup"
}
EOF

# ── 4. تقسيم إذا كبير ──
echo "  ✂️  تجهيز الملفات للرفع..."

# الداتابيس
_db_bytes=$(stat -c '%s' "$TMP/db.sql.gz" 2>/dev/null || echo 0)
if [ "$_db_bytes" -gt 47185920 ]; then
  # أكبر من 45MB - نقسم
  split -b "$CHUNK_SIZE" -d -a 3 "$TMP/db.sql.gz" "$TMP/parts/db.sql.gz.part_"
  rm -f "$TMP/db.sql.gz"
  _db_parts=$(ls "$TMP/parts"/db.sql.gz.part_* | wc -l)
  echo "  ✅ الداتابيس: $_db_parts أجزاء"
else
  mv "$TMP/db.sql.gz" "$TMP/parts/db.sql.gz"
  echo "  ✅ الداتابيس: ملف واحد"
fi

# الملفات
if [ -f "$TMP/files.tar.gz" ]; then
  _f_bytes=$(stat -c '%s' "$TMP/files.tar.gz" 2>/dev/null || echo 0)
  if [ "$_f_bytes" -gt 47185920 ]; then
    split -b "$CHUNK_SIZE" -d -a 3 "$TMP/files.tar.gz" "$TMP/parts/files.tar.gz.part_"
    rm -f "$TMP/files.tar.gz"
    _f_parts=$(ls "$TMP/parts"/files.tar.gz.part_* | wc -l)
    echo "  ✅ الملفات: $_f_parts أجزاء"
  else
    mv "$TMP/files.tar.gz" "$TMP/parts/files.tar.gz"
    echo "  ✅ الملفات: ملف واحد"
  fi
fi

# ── 5. رفع لـ Telegram ──
echo "  📤 رفع الملفات إلى Telegram..."

MANIFEST=""
UPLOAD_OK=true
FILE_COUNT=0

for f in "$TMP/parts"/*; do
  [ -f "$f" ] || continue
  _fn=$(basename "$f")
  _fs=$(du -h "$f" | cut -f1)

  echo "    📤 $_fn ($Fs)..."

  _try=0
  _result=""
  while [ "$_try" -lt 3 ]; do
    _result=$(tg_send_file "$f" "🗂 #n8n_backup $ID | $_fn" 2>/dev/null || true)
    [ -n "$_result" ] && break
    _try=$((_try + 1))
    echo "    ⚠️ إعادة محاولة $_try/3..."
    sleep 3
  done

  if [ -n "$_result" ]; then
    echo "    ✅ $_fn تم"
    MANIFEST="${MANIFEST}${_result}\n"
    FILE_COUNT=$((FILE_COUNT + 1))
  else
    echo "    ❌ فشل رفع $_fn"
    UPLOAD_OK=false
    break
  fi

  # تأخير بسيط لتجنب rate limit
  sleep 1
done

if [ "$UPLOAD_OK" = "false" ]; then
  echo "  ❌ فشل الرفع"
  tg_send_msg "❌ <b>فشل باك أب</b> $ID" || true
  exit 1
fi

# ── 6. إرسال ملف الاسترجاع (manifest) ──
echo "  📋 إرسال دليل الاسترجاع..."

# manifest يحتوي كل المعلومات اللازمة للاسترجاع
{
  echo "{"
  echo "  \"id\": \"$ID\","
  echo "  \"timestamp\": \"$TS\","
  echo "  \"type\": \"n8n-telegram-backup\","
  echo "  \"version\": \"3.0\","
  echo "  \"file_count\": $FILE_COUNT,"
  echo "  \"files\": ["

  _first=true
  printf "%b" "$MANIFEST" | while IFS='|' read -r _mid _fid _fname; do
    [ -n "$_fid" ] || continue
    if [ "$_first" = "true" ]; then
      _first=false
    else
      echo "    ,"
    fi
    echo "    {\"msg_id\": $_mid, \"file_id\": \"$_fid\", \"name\": \"$_fname\"}"
  done

  echo "  ],"
  echo "  \"tag\": \"#n8n_backup\""
  echo "}"
} > "$TMP/manifest_${ID}.json"

# إرسال المانيفست وتثبيته
_man_result=$(tg_send_file "$TMP/manifest_${ID}.json" \
  "📋 #n8n_manifest #n8n_backup
🕒 $TS
📦 $FILE_COUNT ملفات
🆔 $ID")

if [ -n "$_man_result" ]; then
  _man_msg_id=$(echo "$_man_result" | cut -d'|' -f1)
  # نثبّت رسالة المانيفست حتى نلقاها بسرعة
  tg_pin_msg "$_man_msg_id"
  echo "  ✅ المانيفست تم إرساله وتثبيته"
else
  echo "  ⚠️ فشل إرسال المانيفست"
fi

# ── 7. حفظ الحالة ──
save_state "$ID" "$TS"

# تنظيف
rm -rf "$TMP"

echo ""
echo "┌─────────────────────────────────────┐"
echo "│ ✅ باك أب اكتمل!                    │"
echo "│ 📦 $FILE_COUNT ملفات                 │"
echo "│ 🕒 $TS                               │"
echo "│ 📱 تم الحفظ في Telegram              │"
echo "└─────────────────────────────────────┘"
echo ""
exit 0
