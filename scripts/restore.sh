#!/bin/sh
set -eu
umask 077

: "${TG_BOT_TOKEN:?}"
: "${TG_CHAT_ID:?}"

N8N_DIR="${N8N_DIR:-/home/node/.n8n}"
WORK="${WORK:-/backup-data}"
HIST="$WORK/history"
TG="https://api.telegram.org/bot${TG_BOT_TOKEN}"
TMP="/tmp/restore-$$"

trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT
mkdir -p "$N8N_DIR" "$WORK" "$HIST" "$TMP"

[ -s "$N8N_DIR/database.sqlite" ] && {
  echo "✅ DB موجودة - لا حاجة للاسترجاع"
  exit 0
}

echo "=== 🔍 البحث عن آخر باك أب في Telegram ==="

# ── تحميل ملف صغير فقط (مانيفست) ──
dl_file() {
  _fid="$1"
  _out="$2"
  _try=0
  while [ "$_try" -lt 3 ]; do
    _path=$(curl -sS --max-time 15 \
      "${TG}/getFile?file_id=${_fid}" \
      | jq -r '.result.file_path // empty' 2>/dev/null || true)
    if [ -n "$_path" ]; then
      curl -sS --max-time 60 -o "$_out" \
        "https://api.telegram.org/file/bot${TG_BOT_TOKEN}/${_path}" \
        2>/dev/null && [ -s "$_out" ] && return 0
    fi
    _try=$((_try + 1))
    sleep 3
  done
  return 1
}

# ── تحميل ملف وبث محتواه مباشرة لـ stdout (بدون حفظ) ──
stream_file() {
  _fid="$1"
  _path=$(curl -sS --max-time 15 \
    "${TG}/getFile?file_id=${_fid}" \
    | jq -r '.result.file_path // empty' 2>/dev/null || true)
  [ -n "$_path" ] || return 1
  curl -sS --max-time 300 \
    "https://api.telegram.org/file/bot${TG_BOT_TOKEN}/${_path}" \
    2>/dev/null
}

# ══════════════════════════════════════════════
# الاسترجاع الذكي: streaming بدون تخزين مؤقت
# ══════════════════════════════════════════════
restore_from_manifest() {
  _mfile="$1"

  jq empty "$_mfile" 2>/dev/null || {
    echo "  ❌ المانيفست تالف"
    return 1
  }

  _bid=$(jq -r '.id // "unknown"' "$_mfile" 2>/dev/null || echo "unknown")
  _bdb=$(jq -r '.db_size // "?"' "$_mfile" 2>/dev/null || echo "?")
  _bfc=$(jq -r '.file_count // 0' "$_mfile" 2>/dev/null || echo "0")

  echo "  📋 باك أب: $_bid"
  echo "  📦 ملفات: $_bfc | DB: $_bdb"

  # ── استخرج قوائم الملفات من المانيفست ──
  _db_parts=$(jq -r '.files[] | select(.name | startswith("db.sql.gz")) | "\(.file_id)|\(.name)"' \
    "$_mfile" 2>/dev/null || true)

  _file_parts=$(jq -r '.files[] | select(.name | startswith("files.tar.gz")) | "\(.file_id)|\(.name)"' \
    "$_mfile" 2>/dev/null || true)

  # ── تحقق من وجود DB ──
  if [ -z "$_db_parts" ]; then
    echo "  ❌ لا توجد ملفات DB في المانيفست"
    return 1
  fi

  # ══════════════════════════════════════════
  # استرجاع DB - streaming مباشر بدون تخزين
  # ══════════════════════════════════════════
  echo "  🗄️ استرجاع DB بالبث المباشر..."

  _db_count=$(echo "$_db_parts" | grep -c '|' || echo 0)
  echo "    📦 $_db_count جزء(أجزاء) DB"

  # احذف DB القديمة
  rm -f "$N8N_DIR/database.sqlite" \
        "$N8N_DIR/database.sqlite-wal" \
        "$N8N_DIR/database.sqlite-shm" 2>/dev/null || true

  # بث كل أجزاء DB مرتبة → فك ضغط → بناء DB
  _db_ok=false
  (
    echo "$_db_parts" | sort -t'|' -k2 | while IFS='|' read -r _fid _fn; do
      [ -n "$_fid" ] || continue
      echo "    📥 بث: $_fn" >&2
      stream_file "$_fid" || {
        echo "    ❌ فشل بث: $_fn" >&2
        exit 1
      }
    done
  ) | gzip -dc | sqlite3 "$N8N_DIR/database.sqlite" 2>/dev/null && _db_ok=true

  if [ "$_db_ok" = "false" ] || [ ! -s "$N8N_DIR/database.sqlite" ]; then
    echo "  ❌ فشل بناء قاعدة البيانات"
    rm -f "$N8N_DIR/database.sqlite" 2>/dev/null || true
    return 1
  fi

  _tc=$(sqlite3 "$N8N_DIR/database.sqlite" \
    "SELECT count(*) FROM sqlite_master WHERE type='table';" \
    2>/dev/null || echo 0)

  if [ "$_tc" -eq 0 ]; then
    echo "  ❌ قاعدة البيانات فارغة"
    rm -f "$N8N_DIR/database.sqlite" 2>/dev/null || true
    return 1
  fi

  echo "  ✅ DB جاهزة - $_tc جدول"

  # ══════════════════════════════════════════
  # استرجاع الملفات - streaming مع تخطي
  # binaryData تلقائياً إذا كانت كبيرة
  # ══════════════════════════════════════════
  if [ -n "$_file_parts" ]; then
    _file_count=$(echo "$_file_parts" | grep -c '|' || echo 0)
    echo "  📁 استرجاع الإعدادات بالبث المباشر ($_file_count جزء)..."

    # إذا كان أكثر من 10 أجزاء = binaryData ضخمة = نتخطى
    if [ "$_file_count" -gt 10 ]; then
      echo "  ⚠️ الملفات كبيرة جداً ($_file_count × 18MB)"
      echo "  ⏭️ تخطي binaryData - فقط إعدادات n8n أساسية"

      # نحمل أول جزء فقط (يحتوي على الإعدادات الأساسية)
      _first_fid=$(echo "$_file_parts" | sort -t'|' -k2 | head -1 | cut -d'|' -f1)
      _first_fn=$(echo "$_file_parts" | sort -t'|' -k2 | head -1 | cut -d'|' -f2)

      if [ -n "$_first_fid" ]; then
        echo "    📥 بث الإعدادات الأساسية: $_first_fn"
        stream_file "$_first_fid" | gzip -dc | \
          tar -C "$N8N_DIR" -xf - \
            --exclude='./binaryData/*' \
            --exclude='binaryData/*' \
            2>/dev/null || true
        echo "  ✅ الإعدادات الأساسية مسترجعة"
      fi
    else
      # أجزاء قليلة - stream الكل
      (
        echo "$_file_parts" | sort -t'|' -k2 | while IFS='|' read -r _fid _fn; do
          [ -n "$_fid" ] || continue
          echo "    📥 بث: $_fn" >&2
          stream_file "$_fid" || true
        done
      ) | gzip -dc | \
        tar -C "$N8N_DIR" -xf - \
          --exclude='./binaryData/*' \
          --exclude='binaryData/*' \
          2>/dev/null || true
      echo "  ✅ الملفات مسترجعة"
    fi
  else
    echo "  ℹ️ لا توجد ملفات إعدادات"
  fi

  # حفظ المانيفست محلياً
  cp "$_mfile" "$HIST/${_bid}.json" 2>/dev/null || true

  echo ""
  echo "  🎉 اكتمل الاسترجاع!"
  echo "  🆔 $_bid | 📋 $_tc جدول"
  return 0
}

# ════════════════════════════════
# الطريقة 1: الرسالة المثبّتة
# ════════════════════════════════
echo ""
echo "🔍 [1/3] البحث في الرسالة المثبّتة..."

_chat_info=$(curl -sS --max-time 15 \
  "${TG}/getChat?chat_id=${TG_CHAT_ID}" 2>/dev/null || true)

_pin_fid=$(echo "$_chat_info" | \
  jq -r '.result.pinned_message.document.file_id // empty' \
  2>/dev/null || true)

_pin_cap=$(echo "$_chat_info" | \
  jq -r '.result.pinned_message.caption // ""' \
  2>/dev/null || true)

if [ -n "$_pin_fid" ] && echo "$_pin_cap" | grep -q "n8n_manifest"; then
  echo "  📌 وجدنا مانيفست مثبّت!"
  if dl_file "$_pin_fid" "$TMP/manifest_pin.json" 3>/dev/null; then
    if restore_from_manifest "$TMP/manifest_pin.json"; then
      exit 0
    fi
    echo "  ⚠️ فشل - نجرب طريقة أخرى"
  fi
else
  echo "  📭 لا يوجد مانيفست مثبّت"
fi

# ════════════════════════════════
# الطريقة 2: رسائل القناة
# ════════════════════════════════
echo ""
echo "🔍 [2/3] البحث في رسائل القناة..."

_updates=$(curl -sS --max-time 20 \
  "${TG}/getUpdates?offset=-100&limit=100" 2>/dev/null || true)

_found_fid=$(echo "$_updates" | jq -r '
  [
    .result[] |
    select(
      (.channel_post.document != null) and
      ((.channel_post.caption // "") | test("n8n_manifest"))
    )
  ] |
  sort_by(-.channel_post.date) |
  .[0].channel_post.document.file_id // empty
' 2>/dev/null || true)

if [ -n "$_found_fid" ]; then
  echo "  📋 وجدنا مانيفست!"
  if dl_file "$_found_fid" "$TMP/manifest_search.json"; then
    if restore_from_manifest "$TMP/manifest_search.json"; then
      exit 0
    fi
  fi
else
  echo "  📭 لم نجد مانيفست"
fi

# ════════════════════════════════
# الطريقة 3: السجل المحلي
# ════════════════════════════════
echo ""
echo "🔍 [3/3] البحث في السجل المحلي..."

_local=$(ls -t "$HIST"/*.json 2>/dev/null | head -1 || true)
if [ -n "$_local" ] && [ -f "$_local" ]; then
  echo "  📂 وجدنا: $(basename "$_local")"
  if restore_from_manifest "$_local"; then
    exit 0
  fi
else
  echo "  📭 لا يوجد سجل محلي"
fi

echo ""
echo "📭 لا توجد نسخة - n8n سيبدأ من جديد"
exit 0
