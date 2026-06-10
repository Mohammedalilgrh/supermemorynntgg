#!/bin/sh
set -eu
umask 077

: "${TG_BOT_TOKEN:?}"
: "${TG_CHAT_ID:?}"

N8N_DIR="${N8N_DIR:-/home/node/.n8n}"
WORK="${WORK:-/backup-data}"

MIN_INT="${MIN_BACKUP_INTERVAL_SEC:-600}"
FORCE_INT="${FORCE_BACKUP_EVERY_SEC:-21600}"
GZIP_LVL="${GZIP_LEVEL:-9}"

STATE="$WORK/.backup_state"
LOCK="$WORK/.backup_lock"
TMP="$WORK/_bkp_tmp"

TG="https://api.telegram.org/bot${TG_BOT_TOKEN}"

mkdir -p "$WORK"

# ── القفل ──
if ! mkdir "$LOCK" 2>/dev/null; then exit 0; fi
trap 'rmdir "$LOCK" 2>/dev/null; rm -rf "$TMP" 2>/dev/null' EXIT

# ═══════════════════════════════════════════════════════
# ⭐ تنظيف شامل - نحذف كل شيء غير ضروري للاستعادة
# ═══════════════════════════════════════════════════════
clean_copy() {
  _copy="$1"
  [ -s "$_copy" ] || return 1

  echo "  🧹 جاري التنظيف العميق..."

  sqlite3 "$_copy" "
    -- ═══ بيانات التنفيذ (الأكبر حجماً) ═══
    DELETE FROM execution_entity;
    DELETE FROM execution_data;
    DELETE FROM execution_metadata;
    DELETE FROM execution_annotations;
    
    -- ═══ إحصائيات وسجلات ═══
    DELETE FROM workflow_statistics;
    DELETE FROM event_destinations;
    DELETE FROM auth_provider_sync_history;
    DELETE FROM audit_logs;
    DELETE FROM log_entity;
    
    -- ═══ ويب هوكس قديمة ═══
    DELETE FROM webhook_entity WHERE 
      updatedAt < datetime('now', '-30 days') 
      AND active = 0;
    
    -- ═══ تنفيذات معلقة/فاشلة ═══
    DELETE FROM execution_entity WHERE 
      status IN ('error', 'cancelled', 'waiting') 
      AND startedAt < datetime('now', '-7 days');
    
    -- ═══ بيانات قديمة في الجداول الأساسية ═══
    DELETE FROM workflow_entity WHERE 
      active = 0 
      AND updatedAt < datetime('now', '-90 days')
      AND id NOT IN (SELECT DISTINCT workflowId FROM shared_workflow);
    
    -- ═══ تنظيف credentials غير المستخدمة ═══
    DELETE FROM credentials_entity WHERE 
      updatedAt < datetime('now', '-180 days')
      AND id NOT IN (SELECT DISTINCT credentialsId FROM shared_credentials);
    
    -- ═══ user API keys قديمة ═══
    DELETE FROM user_api_keys WHERE 
      expires_at IS NOT NULL 
      AND expires_at < datetime('now');
      
  " 2>/dev/null || true

  # VACUUM لتقليص الملف فعلياً
  echo "  🗜️ جاري ضغط قاعدة البيانات..."
  sqlite3 "$_copy" "VACUUM;"
  sqlite3 "$_copy" "PRAGMA optimize;"
  sqlite3 "$_copy" "PRAGMA analysis_limit=400;"
  sqlite3 "$_copy" "PRAGMA auto_vacuum=FULL;"
  sqlite3 "$_copy" "VACUUM;" 2>/dev/null || true
  
  # ⭐ إعادة تنظيم الملف لتقليل الحجم أكثر
  sqlite3 "$_copy" ".schema" > /dev/null 2>&1 || true
  
  echo "  ✅ اكتمل التنظيف"
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

TS_LABEL=$(date +"%Y-%m-%d_%H-%M-%S")
TS_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

echo "┌─────────────────────────────────────┐"
echo "│ 📦 باك أب: $TS_LABEL ($DEC)"
echo "└─────────────────────────────────────┘"

rm -rf "$TMP"; mkdir -p "$TMP"

# ── نسخ آمن للقاعدة مع WAL ──
echo "  📋 نسخ قاعدة البيانات..."
DB_COPY="$TMP/db_work.sqlite"

# نسخة متسقة مع WAL
sqlite3 "$N8N_DIR/database.sqlite" \
  ".timeout 15000" \
  "VACUUM INTO '$DB_COPY'" 2>/dev/null || \
sqlite3 "$N8N_DIR/database.sqlite" \
  ".timeout 15000" \
  ".backup '$DB_COPY'" 2>/dev/null || \
cp "$N8N_DIR/database.sqlite" "$DB_COPY"

[ -s "$DB_COPY" ] || { echo "  ❌ فشل نسخ DB"; exit 1; }

_size_raw=$(stat -c '%s' "$DB_COPY" 2>/dev/null || echo 0)
echo "  📊 حجم النسخة الخام: $(numfmt --to=iec $_size_raw 2>/dev/null || echo "${_size_raw} bytes")"

# ── تنظيف عميق ──
clean_copy "$DB_COPY"

_size_clean=$(stat -c '%s' "$DB_COPY" 2>/dev/null || echo 0)
echo "  📊 حجم بعد التنظيف: $(numfmt --to=iec $_size_clean 2>/dev/null || echo "${_size_clean} bytes")"

# ── تصدير SQL ──
echo "  🗄️ تصدير SQL..."
EXPORT_FILE="$TMP/db.sql"
sqlite3 "$DB_COPY" ".timeout 10000" ".dump" > "$EXPORT_FILE" 2>/dev/null
rm -f "$DB_COPY"

[ -s "$EXPORT_FILE" ] || { echo "  ❌ فشل التصدير"; exit 1; }

# ⭐ ضغط بأقصى مستوى مع خوارزمية أفضل
FINAL_FILE="$TMP/db_${TS_LABEL}.sql.gz"
gzip -n -"${GZIP_LVL}" --best -c "$EXPORT_FILE" > "$FINAL_FILE"
rm -f "$EXPORT_FILE"

[ -s "$FINAL_FILE" ] || { echo "  ❌ فشل الضغط"; exit 1; }

DB_SIZE=$(du -h "$FINAL_FILE" | cut -f1)
_db_bytes=$(stat -c '%s' "$FINAL_FILE" 2>/dev/null || echo 0)
echo "  ✅ الحجم النهائي: $DB_SIZE ($_db_bytes bytes)"

# ⭐ رفع مباشر بدون حد للحجم
_fn=$(basename "$FINAL_FILE")
echo "  📤 رفع $_fn ($DB_SIZE)..."

_caption="📦 #n8n_backup
🆔 ${TS_LABEL}
📄 ${_fn}
💾 ${DB_SIZE}
🔍 ${DEC}
📊 Raw: $(numfmt --to=iec $_size_raw 2>/dev/null || echo "${_size_raw}B") → Clean: $(numfmt --to=iec $_size_clean 2>/dev/null || echo "${_size_clean}B")"

# ⭐ نظام رفع محسن مع retry
_try=0
LAST_MSG_ID=""
MAX_RETRIES=5

while [ "$_try" -lt "$MAX_RETRIES" ]; do
  _try=$((_try + 1))
  
  # زيادة timeout للملفات الكبيرة
  _resp=$(curl -sS --max-time 300 -X POST "${TG}/sendDocument" \
    -F "chat_id=${TG_CHAT_ID}" \
    -F "document=@${FINAL_FILE};filename=${_fn}" \
    -F "caption=${_caption}" \
    -F "disable_notification=true" \
    2>/dev/null || true)

  _rok=$(echo "$_resp" | jq -r '.ok // "false"' 2>/dev/null || true)
  _mid=$(echo "$_resp" | jq -r '.result.message_id // empty' 2>/dev/null || true)
  _err=$(echo "$_resp" | jq -r '.description // "unknown"' 2>/dev/null || true)

  if [ "$_rok" = "true" ] && [ -n "$_mid" ]; then
    LAST_MSG_ID="$_mid"
    echo "    ✅ تم الرفع بنجاح! (محاولة $_try) msg_id=$_mid"
    break
  fi

  echo "    ⚠️ محاولة $_try/$MAX_RETRIES فشلت: $_err"
  
  if [ "$_try" -lt "$MAX_RETRIES" ]; then
    _wait=$((_try * 5))
    echo "    ⏳ انتظار ${_wait} ثواني..."
    sleep "$_wait"
  fi
done

if [ -z "$LAST_MSG_ID" ]; then
  # ⭐ فشل الرفع - إرسال إشعار فقط
  echo "  ❌ فشل الرفع بعد $MAX_RETRIES محاولات"
  curl -sS -X POST "${TG}/sendMessage" \
    -d "chat_id=${TG_CHAT_ID}" \
    -d "text=⚠️ #n8n_backup_error%0A❌ فشل رفع الملف%0A📊 الحجم: ${DB_SIZE}%0A🕐 ${TS_ISO}%0A🔍 السبب: $_err" \
    >/dev/null 2>&1 || true
  exit 1
fi

# ── تثبيت الرسالة ──
curl -sS -X POST "${TG}/pinChatMessage" \
  -d "chat_id=${TG_CHAT_ID}" \
  -d "message_id=${LAST_MSG_ID}" \
  -d "disable_notification=true" >/dev/null 2>&1 || true
echo "  📌 تم تثبيت الرسالة!"

# ── حفظ الحالة ──
cat > "$STATE" <<EOF
ID=$TS_LABEL
TS=$TS_ISO
LE=$(date +%s)
LF=$(date +%s)
LD=$(db_sig)
SZ=$DB_SIZE
RAW=$_size_raw
CLEAN=$_size_clean
EOF

rm -rf "$TMP"
echo ""
echo "╔══════════════════════════════════════╗"
echo "║ ✅ اكتمل الباك أب بنجاح!           ║"
echo "║ 📦 $TS_LABEL                  ║"
echo "║ 💾 $DB_SIZE                     ║"
echo "║ 📊 تم التنظيف: $(numfmt --to=iec $_size_raw 2>/dev/null || echo "${_size_raw}B") → $(numfmt --to=iec $_size_clean 2>/dev/null || echo "${_size_clean}B")"
echo "╚══════════════════════════════════════╝"
exit 0
