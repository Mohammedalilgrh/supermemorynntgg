#!/bin/sh
set -eu
umask 077

: "${TG_BOT_TOKEN:?}"
: "${TG_CHAT_ID:?}"

N8N_DIR="${N8N_DIR:-/home/node/.n8n}"
WORK="${WORK:-/backup-data}"

TG_API="https://api.telegram.org/bot${TG_BOT_TOKEN}"
TMP="/tmp/restore-$$"

trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT
mkdir -p "$N8N_DIR" "$WORK" "$TMP"

# إذا موجودة لا نسترجع
if [ -s "$N8N_DIR/database.sqlite" ]; then
  echo "✅ قاعدة البيانات موجودة"
  exit 0
fi

echo "=== 🔍 البحث عن آخر باك أب في Telegram ==="
echo ""

# ── دوال Telegram ──

tg_download_file() {
  _file_id="$1"
  _save_as="$2"

  # أولاً: نحصل على مسار الملف
  _path=$(curl -sS "${TG_API}/getFile?file_id=${_file_id}" \
    | jq -r '.result.file_path // empty' 2>/dev/null)

  if [ -z "$_path" ]; then
    echo "  ❌ ما لقينا مسار الملف"
    return 1
  fi

  # ثانياً: نحمّل الملف
  curl -sS -o "$_save_as" \
    "https://api.telegram.org/file/bot${TG_BOT_TOKEN}/${_path}"

  [ -s "$_save_as" ] && return 0 || return 1
}

# ══════════════════════════════════════
# الطريقة 1: نبحث عن المانيفست المثبّت
# ══════════════════════════════════════
echo "🔍 [1/3] البحث عن رسالة مثبّتة..."

PINNED=$(curl -sS "${TG_API}/getChat?chat_id=${TG_CHAT_ID}" \
  | jq -r '.result.pinned_message // empty' 2>/dev/null)

if [ -n "$PINNED" ] && [ "$PINNED" != "null" ]; then
  # نفحص إذا الرسالة المثبّتة فيها document
  _pin_file_id=$(echo "$PINNED" | jq -r '.document.file_id // empty' 2>/dev/null)
  _pin_caption=$(echo "$PINNED" | jq -r '.caption // ""' 2>/dev/null)

  if [ -n "$_pin_file_id" ] && echo "$_pin_caption" | grep -q "n8n_manifest"; then
    echo "  📌 لقينا مانيفست مثبّت!"

    # نحمّل المانيفست
    if tg_download_file "$_pin_file_id" "$TMP/manifest.json"; then
      echo "  ✅ تم تحميل المانيفست"

      # نقرأ قائمة الملفات
      _fcount=$(jq -r '.file_count // 0' "$TMP/manifest.json" 2>/dev/null || echo 0)
      _bid=$(jq -r '.id // "unknown"' "$TMP/manifest.json" 2>/dev/null || echo "unknown")

      echo "  📋 باك أب: $_bid ($_fcount ملفات)"

      # نحمّل كل ملف
      _all_ok=true
      jq -r '.files[] | "\(.file_id)|\(.name)"' "$TMP/manifest.json" 2>/dev/null | \
      while IFS='|' read -r _fid _fname; do
        [ -n "$_fid" ] || continue
        echo "  📥 تحميل: $_fname..."

        _try=0
        while [ "$_try" -lt 3 ]; do
          if tg_download_file "$_fid" "$TMP/$_fname"; then
            echo "    ✅ تم"
            break
          fi
          _try=$((_try + 1))
          echo "    ⚠️ إعادة محاولة $_try/3..."
          sleep 2
        done

        if [ ! -s "$TMP/$_fname" ]; then
          echo "    ❌ فشل تحميل $_fname"
          touch "$TMP/.download_failed"
        fi
        sleep 1
      done

      if [ ! -f "$TMP/.download_failed" ]; then
        echo ""
        echo "  🗄️  استرجاع قاعدة البيانات..."

        # تجميع وفك ضغط الداتابيس
        if [ -f "$TMP/db.sql.gz" ]; then
          gzip -dc "$TMP/db.sql.gz" | sqlite3 "$N8N_DIR/database.sqlite"
        elif ls "$TMP"/db.sql.gz.part_* >/dev/null 2>&1; then
          cat "$TMP"/db.sql.gz.part_* | gzip -dc | sqlite3 "$N8N_DIR/database.sqlite"
        fi

        if [ -s "$N8N_DIR/database.sqlite" ]; then
          _tc=$(sqlite3 "$N8N_DIR/database.sqlite" \
            "SELECT count(*) FROM sqlite_master WHERE type='table';" 2>/dev/null || echo 0)

          if [ "$_tc" -gt 0 ]; then
            echo "  ✅ تم استرجاع $_tc جدول"

            # استرجاع الملفات
            if [ -f "$TMP/files.tar.gz" ]; then
              echo "  📁 استرجاع الملفات..."
              gzip -dc "$TMP/files.tar.gz" | tar -C "$N8N_DIR" -xf - 2>/dev/null || true
              echo "  ✅ تم"
            elif ls "$TMP"/files.tar.gz.part_* >/dev/null 2>&1; then
              echo "  📁 استرجاع الملفات..."
              cat "$TMP"/files.tar.gz.part_* | gzip -dc | tar -C "$N8N_DIR" -xf - 2>/dev/null || true
              echo "  ✅ تم"
            fi

            echo ""
            echo "🎉 استرجاع ناجح من المانيفست المثبّت!"
            exit 0
          else
            echo "  ❌ الداتابيس فارغة"
            rm -f "$N8N_DIR/database.sqlite"
          fi
        fi
      fi
    fi
  fi
fi

echo "  📭 لا يوجد مانيفست مثبّت صالح"
echo ""

# ══════════════════════════════════════
# الطريقة 2: نبحث في آخر الرسائل
# ══════════════════════════════════════
echo "🔍 [2/3] البحث في آخر الرسائل..."

# نجيب آخر الرسائل ونبحث عن مانيفست
# Telegram Bot API ما يعطي تاريخ الرسائل مباشرة
# بس نكدر نستخدم getUpdates أو نبحث عن الملفات

# نبحث عن آخر رسالة فيها #n8n_manifest
# نستخدم search عن طريق forwarding trick

# الحل: نبحث في آخر 100 رسالة عن المانيفست
echo "  🔄 جاري البحث..."

# نحاول نحصل على آخر رسائل عبر getUpdates
_updates=$(curl -sS "${TG_API}/getUpdates?offset=-100&limit=100" \
  | jq -r '.result // []' 2>/dev/null)

if [ -n "$_updates" ] && [ "$_updates" != "[]" ] && [ "$_updates" != "null" ]; then
  # نبحث عن رسائل فيها n8n_manifest
  _manifest_msgs=$(echo "$_updates" | jq -r '
    [.[] | select(
      .message.chat.id == (env.TG_CHAT_ID | tonumber) and
      .message.document != null and
      (.message.caption // "" | contains("n8n_manifest"))
    )] | sort_by(-.message.date) | .[0].message.document.file_id // empty
  ' 2>/dev/null || true)

  if [ -n "$_manifest_msgs" ]; then
    echo "  📋 لقينا مانيفست في الرسائل الأخيرة!"
    if tg_download_file "$_manifest_msgs" "$TMP/manifest2.json"; then
      # نعيد نفس عملية الاسترجاع
      jq -r '.files[] | "\(.file_id)|\(.name)"' "$TMP/manifest2.json" 2>/dev/null | \
      while IFS='|' read -r _fid _fname; do
        [ -n "$_fid" ] || continue
        echo "    📥 $_fname..."
        tg_download_file "$_fid" "$TMP/$_fname" 2>/dev/null || true
        sleep 1
      done

      if [ -f "$TMP/db.sql.gz" ]; then
        gzip -dc "$TMP/db.sql.gz" | sqlite3 "$N8N_DIR/database.sqlite" 2>/dev/null
      elif ls "$TMP"/db.sql.gz.part_* >/dev/null 2>&1; then
        cat "$TMP"/db.sql.gz.part_* | gzip -dc | sqlite3 "$N8N_DIR/database.sqlite" 2>/dev/null
      fi

      if [ -s "$N8N_DIR/database.sqlite" ]; then
        # ملفات إضافية
        if [ -f "$TMP/files.tar.gz" ]; then
          gzip -dc "$TMP/files.tar.gz" | tar -C "$N8N_DIR" -xf - 2>/dev/null || true
        elif ls "$TMP"/files.tar.gz.part_* >/dev/null 2>&1; then
          cat "$TMP"/files.tar.gz.part_* | gzip -dc | tar -C "$N8N_DIR" -xf - 2>/dev/null || true
        fi

        echo "🎉 استرجاع ناجح من الرسائل!"
        exit 0
      fi
    fi
  fi
fi

echo "  📭 لم يتم العثور على مانيفست"
echo ""

# ══════════════════════════════════════
# الطريقة 3: نبحث عن أي ملف db.sql.gz
# ══════════════════════════════════════
echo "🔍 [3/3] بحث عام عن ملفات الباك أب..."

# نبحث في آخر الرسائل عن أي ملف يبدأ بـ db.sql.gz
if [ -n "$_updates" ] && [ "$_updates" != "[]" ] && [ "$_updates" != "null" ]; then
  _db_file=$(echo "$_updates" | jq -r '
    [.[] | select(
      .message.chat.id == (env.TG_CHAT_ID | tonumber) and
      .message.document != null and
      (.message.document.file_name // "" | startswith("db.sql.gz"))
    )] | sort_by(-.message.date) | .[0].message.document.file_id // empty
  ' 2>/dev/null || true)

  if [ -n "$_db_file" ]; then
    echo "  📥 لقينا ملف داتابيس!"
    if tg_download_file "$_db_file" "$TMP/db_direct.sql.gz"; then
      gzip -dc "$TMP/db_direct.sql.gz" | sqlite3 "$N8N_DIR/database.sqlite" 2>/dev/null || true
      if [ -s "$N8N_DIR/database.sqlite" ]; then
        echo "🎉 استرجاع ناجح!"
        exit 0
      fi
    fi
  fi
fi

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║  📭 لا توجد أي نسخة احتياطية            ║"
echo "║  🆕 سيبدأ n8n كتشغيل أول                ║"
echo "╚══════════════════════════════════════════╝"
echo ""
exit 1
