#!/bin/sh
set -eu
umask 077

: "${TG_BOT_TOKEN:?}"
: "${TG_CHAT_ID:?}"

N8N_DIR="${N8N_DIR:-/home/node/.n8n}"
WORK="${WORK:-/backup-data}"

MIN_INT="${MIN_BACKUP_INTERVAL_SEC:-600}"
FORCE_INT="${FORCE_BACKUP_EVERY_SEC:-21600}"
# ⭐ رفعنا الضغط لأقصى مستوى (9) لتصغير الملف قدر الإمكان
GZIP_LVL="${GZIP_LEVEL:-9}"

STATE="$WORK/.backup_state"
LOCK="$WORK/.backup_lock"
TMP="$WORK/_bkp_tmp"

TG="https://api.telegram.org/bot${TG_BOT_TOKEN}"

mkdir -p "$WORK"

# ── القفل ──
if ! mkdir "$LOCK" 2>/dev/null; then exit 0; fi
trap 'rmdir "$LOCK" 2>/dev/null; rm -rf "$TMP" 2>/dev/null' EXIT

# ══════════════════════════════════════
# ⭐ تنظيف عدواني على النسخة فقط — لا نلمس الـ DB الحية أبداً
#
# الجداول المحذوفة (غير ضرورية للريستور):
#   execution_entity      — سجلات تنفيذ الـ workflows
#   execution_data        — بيانات الـ nodes داخل كل تنفيذ
#   execution_metadata    — metadata التنفيذ
#   execution_annotations — تعليقات على التنفيذ (n8n ≥1.30)
#   workflow_statistics   — إحصائيات تشغيل الـ workflows
#   event_destinations    — إعدادات اللوغ (تُعاد تلقائياً)
#   auth_provider_sync_history — سجل مزامنة LDAP/SAML
#
# الجداول المحتفظ بها (الجوهر):
#   workflow_entity, credentials_entity, settings,
#   variables, tag_entity, workflows_tags,
#   webhook_entity, installed_packages, installed_nodes,
#   role, user, shared_workflow, shared_credentials,
#   project, project_relation, folder
# ══════════════════════════════════════
clean_copy() {
  _copy="$1"
  [ -s "$_copy" ] || return 1

  sqlite3 "$_copy" "
    DELETE FROM execution_entity         WHERE 1=1;
    DELETE FROM execution_data           WHERE 1=1;
    DELETE FROM execution_metadata       WHERE 1=1;
    DELETE FROM workflow_statistics      WHERE 1=1;
    DELETE FROM event_destinations       WHERE 1=1;
  " 2>/dev/null || true

  # هذين الجدولين قد لا يوجدان في إصدارات قديمة
  sqlite3 "$_copy" "DELETE FROM execution_annotations    WHERE 1=1;" 2>/dev/null || true
  sqlite3 "$_copy" "DELETE FROM auth_provider_sync_history WHERE 1=1;" 2>/dev/null || true

  # تقليص الحجم الفعلي على القرص
  sqlite3 "$_copy" "VACUUM; PRAGMA optimize;" 2>/dev/null || true
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

# ── نسخ الـ DB الحية إلى ملف مؤقت (atomic + WAL-safe) ──
echo "  📋 نسخ DB..."
DB_COPY="$TMP/db_work.sqlite"

# sqlite3 .backup يضمن نسخة متسقة حتى لو n8n شغال
sqlite3 "$N8N_DIR/database.sqlite" \
  ".timeout 15000" \
  ".backup $DB_COPY" 2>/dev/null || {
  # فول باك: نسخ مباشر
  cp "$N8N_DIR/database.sqlite" "$DB_COPY"
}

[ -s "$DB_COPY" ] || { echo "  ❌ فشل نسخ DB"; exit 1; }
echo "  ✅ حجم النسخة الخام: $(du -h "$DB_COPY" | cut -f1)"

# ── تنظيف على النسخة فقط — الـ DB الحية لا تُمس ──
echo "  🧹 تنظيف النسخة (بيانات التنفيذ + الإحصائيات)..."
clean_copy "$DB_COPY"
echo "  ✅ حجم بعد التنظيف: $(du -h "$DB_COPY" | cut -f1)"

# ── dump SQL من النسخة المنظّفة ──
echo "  🗄️ تصدير SQL..."
EXPORT_FILE="$TMP/db.sql"
sqlite3 "$DB_COPY" ".timeout 10000" ".dump" > "$EXPORT_FILE" 2>/dev/null
rm -f "$DB_COPY"

[ -s "$EXPORT_FILE" ] || { echo "  ❌ فشل التصدير"; exit 1; }

# ⭐ ضغط بأقصى مستوى (9)
FINAL_FILE="$TMP/db_${TS_LABEL}.sql.gz"
gzip -n -9 -c "$EXPORT_FILE" > "$FINAL_FILE"
rm -f "$EXPORT_FILE"

[ -s "$FINAL_FILE" ] || { echo "  ❌ فشل التصدير"; exit 1; }

DB_SIZE=$(du -h "$FINAL_FILE" | cut -f1)
_db_bytes=$(stat -c '%s' "$FINAL_FILE" 2>/dev/null || echo 0)
echo "  ✅ DB: $DB_SIZE ($DEC)"

# ── تحقق من الحجم — لو لا زال أكبر من 18MB نوقف ونبلغ ──
CHUNK_BYTES=18874368
if [ "$_db_bytes" -gt "$CHUNK_BYTES" ]; then
  echo "  ❌ الملف لا زال كبيراً جداً ($_db_bytes bytes) بعد التنظيف والضغط!"
  curl -sS -X POST "${TG}/sendMessage" \
    -d "chat_id=${TG_CHAT_ID}" \
    -d "text=⚠️ #n8n_backup_error%0A❌ الملف تجاوز 18MB بعد التنظيف والضغط%0A📊 الحجم: ${DB_SIZE}%0A🕐 ${TS_ISO}" \
    >/dev/null 2>&1 || true
  exit 1
fi

# ── رفع لـ Telegram (ملف واحد دائماً) ──
_fn=$(basename "$FINAL_FILE")
echo "  📤 رفع $_fn ($DB_SIZE)..."

_caption="📦 #n8n_backup
🆔 ${TS_LABEL}
📄 ${_fn}
💾 ${DB_SIZE}
🔍 ${DEC}"

_try=0; LAST_MSG_ID=""
while [ "$_try" -lt 3 ]; do
  _resp=$(curl -sS -X POST "${TG}/sendDocument" \
    -F "chat_id=${TG_CHAT_ID}" \
    -F "document=@${FINAL_FILE};filename=${_fn}" \
    -F "caption=${_caption}" \
    2>/dev/null || true)

  _rok=$(echo "$_resp" | jq -r '.ok // "false"' 2>/dev/null || true)
  _mid=$(echo "$_resp" | jq -r '.result.message_id // empty' 2>/dev/null || true)

  if [ "$_rok" = "true" ] && [ -n "$_mid" ]; then
    LAST_MSG_ID="$_mid"
    echo "    ✅ تم الرفع! msg_id=$_mid"
    break
  fi

  _try=$((_try + 1))
  echo "    ⚠️ محاولة $_try فشلت، إعادة بعد 3 ثوان..."
  sleep 3
done

[ -n "$LAST_MSG_ID" ] || { echo "  ❌ فشل الرفع بعد 3 محاولات"; exit 1; }

# ── تثبيت الرسالة ──
curl -sS -X POST "${TG}/pinChatMessage" \
  -d "chat_id=${TG_CHAT_ID}" \
  -d "message_id=${LAST_MSG_ID}" \
  -d "disable_notification=true" >/dev/null 2>&1 || true
echo "  📌 مثبّت! (msg_id=$LAST_MSG_ID)"

# ── حفظ الحالة ──
cat > "$STATE" <<EOF
ID=$TS_LABEL
TS=$TS_ISO
LE=$(date +%s)
LF=$(date +%s)
LD=$(db_sig)
SZ=$DB_SIZE
EOF

rm -rf "$TMP"
echo "  ✅ اكتمل! DB: $DB_SIZE"
exit 0
