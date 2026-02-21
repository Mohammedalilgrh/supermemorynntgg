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
    sleep 2
  done
  return 1
}

# ── تحميل ملف إلى مسار محدد ──
dl_to_file() {
  _fid="$1" _out="$2"
  _path=$(curl -sS --max-time 15 \
    "${TG}/getFile?file_id=${_fid}" \
    | jq -r '.result.file_path // empty' 2>/dev/null || true)
  [ -n "$_path" ] || return 1
  curl -sS --max-time 300 -o "$_out" \
    "https://api.telegram.org/file/bot${TG_BOT_TOKEN}/${_path}" \
    2>/dev/null
  [ -s "$_out" ]
}

# ── بث ملف لـ stdout ──
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
  echo "📋 $_bid | ملفات: $_bfc | DB: $_bdb"

  # قوائم الملفات
  _db_list=$(jq -r \
    '.files[] | select(.name | startswith("db.")) | "\(.file_id)|\(.name)"' \
    "$_mfile" 2>/dev/null || true)

  _cfg_list=$(jq -r \
    '.files[] | select(.name | startswith("files.")) | "\(.file_id)|\(.name)"' \
    "$_mfile" 2>/dev/null || true)

  [ -n "$_db_list" ] || { echo "❌ لا توجد DB"; return 1; }

  _db_count=$(echo "$_db_list" | grep -c '|' || echo 0)
  _cfg_count=$(echo "$_cfg_list" | grep -c '|' 2>/dev/null || echo 0)
  echo "🗄️ DB: $_db_count جزء | 📁 إعدادات: $_cfg_count جزء"

  # ══════════════════════════
  # استرجاع DB
  # ══════════════════════════
  echo "🗄️ استرجاع DB..."
  rm -f "$N8N_DIR/database.sqlite" \
        "$N8N_DIR/database.sqlite-wal" \
        "$N8N_DIR/database.sqlite-shm" 2>/dev/null || true

  if [ "$_db_count" -eq 1 ]; then
    # جزء واحد - تحميل مباشر أكثر أماناً
    _fid=$(echo "$_db_list" | cut -d'|' -f1)
    _fn=$(echo "$_db_list" | cut -d'|' -f2)
    echo "  📥 تحميل: $_fn"

    if dl_to_file "$_fid" "$TMP/db.sql.gz"; then
      gzip -dc "$TMP/db.sql.gz" | \
        sqlite3 "$N8N_DIR/database.sqlite" && \
        rm -f "$TMP/db.sql.gz"
    else
      echo "❌ فشل تحميل DB"
      return 1
    fi
  else
    # أجزاء متعددة - تحميل الكل ثم دمج
    echo "  📦 تحميل $_db_count أجزاء DB..."
    mkdir -p "$TMP/db_parts"

    echo "$_db_list" | sort -t'|' -k2 | while IFS='|' read -r _fid _fn; do
      [ -n "$_fid" ] || continue
      echo "  📥 $_fn"
      dl_to_file "$_fid" "$TMP/db_parts/$_fn" || {
        echo "❌ فشل: $_fn"
        touch "$TMP/db_parts/.failed"
      }
    done

    [ -f "$TMP/db_parts/.failed" ] && {
      echo "❌ فشل تحميل أجزاء DB"
      return 1
    }

    cat $(ls -v "$TMP/db_parts"/db.sql.gz*) | \
      gzip -dc | \
      sqlite3 "$N8N_DIR/database.sqlite"

    rm -rf "$TMP/db_parts"
  fi

  # تحقق
  [ -s "$N8N_DIR/database.sqlite" ] || {
    echo "❌ DB فارغة بعد الاسترجاع"
    return 1
  }

  _tc=$(sqlite3 "$N8N_DIR/database.sqlite" \
    "SELECT count(*) FROM sqlite_master WHERE type='table';" \
    2>/dev/null || echo 0)

  [ "$_tc" -gt 0 ] || {
    echo "❌ DB لا تحتوي جداول"
    rm -f "$N8N_DIR/database.sqlite"
    return 1
  }
  echo "✅ DB: $_tc جدول"

  # ══════════════════════════
  # استرجاع الإعدادات
  # تخطي إذا أجزاء كثيرة جداً
  # ══════════════════════════
  if [ "$_cfg_count" -gt 0 ] && [ "$_cfg_count" -le 3 ]; then
    echo "📁 استرجاع الإعدادات..."
    mkdir -p "$TMP/cfg_parts"

    echo "$_cfg_list" | sort -t'|' -k2 | while IFS='|' read -r _fid _fn; do
      [ -n "$_fid" ] || continue
      echo "  📥 $_fn"
      dl_to_file "$_fid" "$TMP/cfg_parts/$_fn" || true
    done

    if ls "$TMP/cfg_parts"/files.tar.gz* >/dev/null 2>&1; then
      cat $(ls -v "$TMP/cfg_parts"/files.tar.gz*) | \
        gzip -dc | \
        tar -C "$N8N_DIR" -xf - \
          --exclude='./binaryData' \
          --exclude='./binaryData/*' \
          --exclude='./.cache' \
          2>/dev/null || true
      echo "✅ إعدادات مسترجعة"
    fi
    rm -rf "$TMP/cfg_parts"

  elif [ "$_cfg_count" -gt 3 ]; then
    # الملف كبير جداً (binaryData) - تخطي كلياً
    echo "⏭️ تخطي الإعدادات (كبيرة جداً: $_cfg_count جزء)"
    echo "   binaryData في Cloudflare R2 - لا حاجة لاسترجاعها"
  fi

  cp "$_mfile" "$HIST/${_bid}.json" 2>/dev/null || true

  echo ""
  echo "🎉 اكتمل: $_bid | $_tc جدول"
  return 0
}

# ════════════════════════
# طريقة 1: رسالة مثبّتة
# ════════════════════════
echo ""
echo "🔍 [1/3] الرسالة المثبّتة..."

_chat=$(curl -sS --max-time 15 \
  "${TG}/getChat?chat_id=${TG_CHAT_ID}" 2>/dev/null || true)

_pin_fid=$(echo "$_chat" | \
  jq -r '.result.pinned_message.document.file_id // empty' \
  2>/dev/null || true)
_pin_cap=$(echo "$_chat" | \
  jq -r '.result.pinned_message.caption // ""' \
  2>/dev/null || true)

if [ -n "$_pin_fid" ] && echo "$_pin_cap" | grep -q "n8n_manifest"; then
  echo "  📌 مانيفست مثبّت!"
  if dl_file "$_pin_fid" "$TMP/m1.json"; then
    restore_from_manifest "$TMP/m1.json" && exit 0
    echo "  ⚠️ فشل - نجرب طريقة أخرى"
  fi
else
  echo "  📭 لا يوجد"
fi

# ════════════════════════
# طريقة 2: رسائل القناة
# ════════════════════════
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
else
  echo "  📭 لا يوجد"
fi

# ════════════════════════
# طريقة 3: السجل المحلي
# ════════════════════════
echo ""
echo "🔍 [3/3] السجل المحلي..."

_local=$(ls -t "$HIST"/*.json 2>/dev/null | head -1 || true)
if [ -n "$_local" ] && [ -f "$_local" ]; then
  echo "  📂 $(basename "$_local")"
  restore_from_manifest "$_local" && exit 0
else
  echo "  📭 لا يوجد"
fi

echo ""
echo "📭 لا توجد نسخة - سيبدأ n8n من جديد"
exit 0
