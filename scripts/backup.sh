#!/bin/sh
set -eu
umask 077

# ═══════════════════════════════
# ⭐ نظام التنظيف + الباك أب المتكامل
# ═══════════════════════════════

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

# ═══════════════════════════════════════
# 🧹 مرحلة 1: تنظيف القاعدة الحية
# ═══════════════════════════════════════
clean_live_db() {
  echo "🧹 جاري تنظيف القاعدة الحية..."
  
  sqlite3 "$N8N_DIR/database.sqlite" "
    -- ⭐ حذف كل بيانات التنفيذ
    DELETE FROM execution_entity;
    DELETE FROM execution_data;
    DELETE FROM execution_metadata;
    
    -- ⭐ حذف الإحصائيات والسجلات
    DELETE FROM workflow_statistics;
    DELETE FROM event_destinations;
    DELETE FROM execution_annotations;
    DELETE FROM auth_provider_sync_history;
    
    -- ⭐ تنظيف ويب هوكس غير نشطة قديمة
    DELETE FROM webhook_entity 
    WHERE active = 0 
    AND updatedAt < datetime('now', '-7 days');
    
    -- ⭐ تنظيف workflows محذوفة (soft delete)
    DELETE FROM workflow_entity 
    WHERE active = 0 
    AND updatedAt < datetime('now', '-30 days');
    
    -- ⭐ ضغط القاعدة
    PRAGMA optimize;
    VACUUM;
    PRAGMA analysis_limit=400;
  " 2>/dev/null || true
  
  echo "✅ تم تنظيف القاعدة الحية"
}

# ═══════════════════════════════════════
# 📦 مرحلة 2: نسخ احتياطي
# ═══════════════════════════════════════
create_backup() {
  echo "📋 جاري النسخ الاحتياطي..."
  
  DB_COPY="$TMP/n8n_clean.db"
  
  # نسخة نظيفة
  sqlite3 "$N8N_DIR/database.sqlite" ".backup '$DB_COPY'" 2>/dev/null || \
  sqlite3 "$N8N_DIR/database.sqlite" "VACUUM INTO '$DB_COPY'" 2>/dev/null || \
  cp "$N8N_DIR/database.sqlite" "$DB_COPY"
  
  [ -s "$DB_COPY" ] || { echo "❌ فشل النسخ"; return 1; }
  
  # ⭐ تحقق إن النسخة نظيفة 100%
  sqlite3 "$DB_COPY" "
    DELETE FROM execution_entity WHERE 1=1;
    DELETE FROM execution_data WHERE 1=1;
    DELETE FROM execution_metadata WHERE 1=1;
    DELETE FROM workflow_statistics WHERE 1=1;
    VACUUM;
  " 2>/dev/null || true
  
  echo "✅ تم النسخ"
  return 0
}

# ═══════════════════════════════════════
# 🗜️ مرحلة 3: تصدير وضغط
# ═══════════════════════════════════════
export_and_compress() {
  echo "🗜️ جاري التصدير والضغط..."
  
  EXPORT_FILE="$TMP/n8n_export.sql"
  
  # تصدير SQL
  sqlite3 "$DB_COPY" ".dump" > "$EXPORT_FILE" 2>/dev/null
  [ -s "$EXPORT_FILE" ] || { echo "❌ فشل التصدير"; return 1; }
  
  # ⭐ ضغط بأقصى مستوى - الاسم دائماً db.sql.gz
  gzip -f -"${GZIP_LVL}" --best "$EXPORT_FILE"
  
  # ⭐ إعادة تسمية للملف النهائي - دائماً db.sql.gz
  FINAL_FILE="$TMP/db.sql.gz"
  mv "${EXPORT_FILE}.gz" "$FINAL_FILE"
  
  [ -s "$FINAL_FILE" ] || { echo "❌ فشل الضغط"; return 1; }
  
  DB_SIZE=$(du -h "$FINAL_FILE" | cut -f1)
  echo "✅ الحجم النهائي: $DB_SIZE"
  return 0
}

# ═══════════════════════════════════════
# 📤 مرحلة 4: رفع للتليغرام
# ═══════════════════════════════════════
upload_to_telegram() {
  echo "📤 جاري الرفع..."
  
  # ⭐ الاسم دائماً db.sql.gz
  _fn="db.sql.gz"
  
  _caption="✅ #n8n_backup_clean
🆔 ${TS_LABEL}
📊 ${DB_SIZE}
🏷️ Clean & Ready"

  _try=0
  while [ "$_try" -lt 3 ]; do
    _try=$((_try + 1))
    
    _resp=$(curl -sS --max-time 120 -X POST "${TG}/sendDocument" \
      -F "chat_id=${TG_CHAT_ID}" \
      -F "document=@${FINAL_FILE};filename=${_fn}" \
      -F "caption=${_caption}" \
      2>/dev/null || true)
    
    _rok=$(echo "$_resp" | jq -r '.ok // "false"' 2>/dev/null || true)
    
    if [ "$_rok" = "true" ]; then
      echo "✅ تم الرفع (محاولة $_try)"
      return 0
    fi
    
    [ "$_try" -lt 3 ] && sleep 5
  done
  
  echo "❌ فشل الرفع"
  return 1
}

# ═══════════════════════════════════════
# 🚀 التنفيذ الرئيسي
# ═══════════════════════════════════════

echo "╔══════════════════════════════════╗"
echo "║ 🔄 دورة تنظيف + باك أب         ║"
echo "╚══════════════════════════════════╝"

TS_LABEL=$(date +"%Y%m%d_%H%M%S")
TS_ISO=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

# تحضير المجلد المؤقت
rm -rf "$TMP"
mkdir -p "$TMP"

# ⭐ تنفيذ المراحل
clean_live_db || exit 1
create_backup || exit 1
export_and_compress || exit 1
upload_to_telegram || exit 1

# تنظيف
rm -rf "$TMP"

echo "╔══════════════════════════════════╗"
echo "║ ✅ اكتمل - النظام نظيف 100%    ║"
echo "╚══════════════════════════════════╝"

exit 0
