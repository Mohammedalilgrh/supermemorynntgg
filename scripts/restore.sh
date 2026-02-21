#!/bin/bash
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
  echo "✅ DB موجودة"
  exit 0
}

echo "=== 🔍 البحث عن باك أب ==="

# ── تحميل ملف صغير ──
dl_file() {
  _fid="$1" _out="$2"
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

# ── بث ملف مباشرة لـ stdout بدون حفظ ──
stream_file() {
  _fid="$1"
  _path=$(curl -sS --max-time 15 \
    "${TG}/getFile?file_id=${_fid}" \
    | jq -r '.result.file_path // empty' 2>/dev/null || true)
  [ -n "$_path" ] || { echo "❌ لم نحصل على مسار الملف" >&2; return 1; }
  curl -sS --max-time 300 \
    "https://api.telegram.org/file/bot${TG_BOT_TOKEN}/${_path}"
}

# ══════════════════════════════════════════════
# الاسترجاع الرئيسي
# ══════════════════════════════════════════════
restore_from_manifest() {
  _mfile="$1"

  jq empty "$_mfile" 2>/dev/null || {
    echo "❌ المانيفست تالف"
    return 1
  }

  _bid=$(jq -r '.id // "unknown"' "$_mfile")
  _bfc=$(jq -r '.file_count // 0' "$_mfile")
  _bdb=$(jq -r '.db_size // "?"' "$_mfile")

  echo "📋 باك أب: $_bid | ملفات: $_bfc | DB: $_bdb"

  # ── فصل ملفات DB وملفات الإعدادات ──
  _db_list=$(jq -r '.files[] | select(.name | startswith("db.")) | "\(.file_id)|\(.name)"' \
    "$_mfile" 2>/dev/null || true)

  _cfg_list=$(jq -r '.files[] | select(.name | startswith("files.")) | "\(.file_id)|\(.name)"' \
    "$_mfile" 2>/dev/null || true)

  [ -n "$_db_list" ] || { echo "❌ لا توجد ملفات DB"; return 1; }

  _db_count=$(echo "$_db_list" | grep -c '.' || echo 0)
  _cfg_count=$(echo "$_cfg_list" | grep -c '.' 2>/dev/null || echo 0)

  echo "🗄️ DB: $_db_count جزء | 📁 إعدادات: $_cfg_count جزء"

  # ════════════════════════════
  # استرجاع DB بالبث المباشر
  # ════════════════════════════
  echo "🗄️ استرجاع DB..."

  rm -f "$N8N_DIR/database.sqlite" \
        "$N8N_DIR/database.sqlite-wal" \
        "$N8N_DIR/database.sqlite-shm" 2>/dev/null || true

  # بث كل الأجزاء مرتبة → فك ضغط → sqlite
  {
    echo "$_db_list" | sort -t'|' -k2 | while IFS='|' read -r _fid _fn; do
      [ -n "$_fid" ] || continue
      echo "  📥 بث DB: $_fn" >&2
      stream_file "$_fid"
    done
  } | gzip -dc | sqlite3 "$N8N_DIR/database.sqlite"

  [ -s "$N8N_DIR/database.sqlite" ] || {
    echo "❌ فشل بناء DB"
    return 1
  }

  _tc=$(sqlite3 "$N8N_DIR/database.sqlite" \
    "SELECT count(*) FROM sqlite_master WHERE type='table';" 2>/dev/null || echo 0)

  [ "$_tc" -gt 0 ] || {
    echo "❌ DB فارغة"
    rm -f "$N8N_DIR/database.sqlite"
    return 1
  }

  echo "✅ DB جاهزة: $_tc جدول"

  # ════════════════════════════
  # استرجاع الإعدادات
  # بث مباشر - تخطي binaryData
  # ════════════════════════════
  if [ "$_cfg_count" -gt 0 ]; then
    echo "📁 استرجاع إعدادات n8n ($_cfg_count جزء)..."

    if [ "$_cfg_count" -gt 5 ]; then
      # أجزاء كثيرة = كانت تحتوي binaryData
      # نأخذ فقط أول جزء يحتوي الإعدادات الأساسية
      echo "⚠️ أجزاء كثيرة - نستخرج الإعدادات الأساسية فقط"
      _first_fid=$(echo "$_cfg_list" | sort -t'|' -k2 | head -1 | cut -d'|' -f1)
      _first_fn=$(echo "$_cfg_list" | sort -t'|' -k2 | head -1 | cut -d'|' -f2)

      if [ -n "$_first_fid" ]; then
        echo "  📥 بث: $_first_fn"
        stream_file "$_first_fid" | gzip -dc | \
          tar -C "$N8N_DIR" -xf - \
            --exclude='./binaryData' \
            --exclude='./binaryData/*' \
            --exclude='./.cache' \
            2>/dev/null || true
        echo "✅ إعدادات أساسية مسترجعة"
      fi
    else
      # أجزاء قليلة - stream الكل بدون binaryData
      {
        echo "$_cfg_list" | sort -t'|' -k2 | while IFS='|' read -r _fid _fn; do
          [ -n "$_fid" ] || continue
          echo "  📥 بث: $_fn" >&2
          stream_file "$_fid"
        done
      } | gzip -dc | \
        tar -C "$N8N_DIR" -xf - \
          --exclude='./binaryData' \
          --exclude='./binaryData/*' \
          --exclude='./.cache' \
          2>/dev/null || true
      echo "✅ إعدادات مسترجعة"
    fi
  fi

  # حفظ المانيفست محلياً
  cp "$_mfile" "$HIST/${_bid}.json" 2>/dev/null || true

  echo ""
  echo "🎉 اكتمل الاسترجاع: $_bid | $_tc جدول"
  return 0
}

# ════════════════════════════════
# طريقة 1: الرسالة المثبّتة
# ════════════════════════════════
echo ""
echo "🔍 [1/3] الرسالة المثبّتة..."

_chat=$(curl -sS --max-time 15 \
  "${TG}/getChat?chat_id=${TG_CHAT_ID}" 2>/dev/null || true)

_pin_fid=$(echo "$_chat" | jq -r \
  '.result.pinned_message.document.file_id // empty' 2>/dev/null || true)
_pin_cap=$(echo "$_chat" | jq -r \
  '.result.pinned_message.caption // ""' 2>/dev/null || true)

if [ -n "$_pin_fid" ] && echo "$_pin_cap" | grep -q "n8n_manifest"; then
  echo "  📌 مانيفست مثبّت!"
  if dl_file "$_pin_fid" "$TMP/m1.json"; then
    restore_from_manifest "$TMP/m1.json" && exit 0
  fi
fi
echo "  📭 لا يوجد"

# ════════════════════════════════
# طريقة 2: رسائل القناة
# ════════════════════════════════
echo ""
echo "🔍 [2/3] رسائل القناة..."

_upd=$(curl -sS --max-time 20 \
  "${TG}/getUpdates?offset=-100&limit=100" 2>/dev/null || true)

_fid2=$(echo "$_upd" | jq -r '
  [.result[] |
   select(
     (.channel_post.document != null) and
     ((.channel_post.caption // "") | test("n8n_manifest"))
   )] |
  sort_by(-.channel_post.date) |
  .[0].channel_post.document.file_id // empty
' 2>/dev/null || true)

if [ -n "$_fid2" ]; then
  echo "  📋 وجدنا مانيفست!"
  if dl_file "$_fid2" "$TMP/m2.json"; then
    restore_from_manifest "$TMP/m2.json" && exit 0
  fi
fi
echo "  📭 لا يوجد"

# ════════════════════════════════
# طريقة 3: السجل المحلي
# ════════════════════════════════
echo ""
echo "🔍 [3/3] السجل المحلي..."

_local=$(ls -t "$HIST"/*.json 2>/dev/null | head -1 || true)
if [ -n "$_local" ] && [ -f "$_local" ]; then
  echo "  📂 $(basename "$_local")"
  restore_from_manifest "$_local" && exit 0
fi
echo "  📭 لا يوجد"

echo ""
echo "📭 لا توجد نسخة - n8n سيبدأ جديد"
exit 0
