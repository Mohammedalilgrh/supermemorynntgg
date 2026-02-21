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

# ── تحميل ملف ──
dl_file() {
  _fid="$1"
  _out="$2"
  _try=0
  while [ "$_try" -lt 3 ]; do
    _path=$(curl -sS --max-time 15 \
      "${TG}/getFile?file_id=${_fid}" \
      | jq -r '.result.file_path // empty' 2>/dev/null || true)
    if [ -n "$_path" ]; then
      if curl -sS --max-time 120 -o "$_out" \
        "https://api.telegram.org/file/bot${TG_BOT_TOKEN}/${_path}" \
        2>/dev/null; then
        [ -s "$_out" ] && return 0
      fi
    fi
    _try=$((_try + 1))
    echo "    ⚠️ محاولة $_try/3..."
    sleep 3
  done
  return 1
}

# ══════════════════════════════════════════════
# الاسترجاع - DB فقط (هي تحتوي كل شيء)
# credentials, workflows, users, settings
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

  # ── نأخذ فقط ملفات DB ──
  _db_list=$(jq -r \
    '.files[] | select(.name | startswith("db.")) | "\(.file_id)|\(.name)"' \
    "$_mfile" 2>/dev/null | sort -t'|' -k2 || true)

  [ -n "$_db_list" ] || {
    echo "❌ لا توجد ملفات DB في المانيفست"
    return 1
  }

  _db_count=$(echo "$_db_list" | wc -l | tr -d ' ')
  echo "🗄️ DB: $_db_count جزء"

  # ── تنظيف ──
  rm -f "$N8N_DIR/database.sqlite" \
        "$N8N_DIR/database.sqlite-wal" \
        "$N8N_DIR/database.sqlite-shm" 2>/dev/null || true

  # ── تحميل أجزاء DB ──
  mkdir -p "$TMP/db"

  _dl_ok=true
  while IFS='|' read -r _fid _fn; do
    [ -n "$_fid" ] && [ -n "$_fn" ] || continue
    echo "  📥 تحميل: $_fn"
    if ! dl_file "$_fid" "$TMP/db/$_fn"; then
      echo "  ❌ فشل تحميل: $_fn"
      _dl_ok=false
      break
    fi
    _sz=$(du -h "$TMP/db/$_fn" | cut -f1)
    echo "  ✅ $_fn ($_sz)"
  done <<< "$_db_list"

  [ "$_dl_ok" = "true" ] || {
    echo "❌ فشل تحميل DB"
    return 1
  }

  # ── بناء DB من الأجزاء ──
  echo "🔧 بناء قاعدة البيانات..."

  if [ "$_db_count" -eq 1 ]; then
    # جزء واحد مباشر
    _only=$(ls "$TMP/db"/)
    gzip -dc "$TMP/db/$_only" | \
      sqlite3 "$N8N_DIR/database.sqlite"
  else
    # أجزاء متعددة - دمج ثم فك ضغط
    cat $(ls -v "$TMP/db"/db.sql.gz*) | \
      gzip -dc | \
      sqlite3 "$N8N_DIR/database.sqlite"
  fi

  # ── تحقق من صحة DB ──
  if [ ! -s "$N8N_DIR/database.sqlite" ]; then
    echo "❌ فشل - DB فارغة"
    return 1
  fi

  _tc=$(sqlite3 "$N8N_DIR/database.sqlite" \
    "SELECT count(*) FROM sqlite_master WHERE type='table';" \
    2>/dev/null || echo 0)

  if [ "$_tc" -eq 0 ]; then
    echo "❌ DB لا تحتوي جداول"
    rm -f "$N8N_DIR/database.sqlite"
    return 1
  fi

  # ── تحقق من وجود المستخدمين ──
  _users=$(sqlite3 "$N8N_DIR/database.sqlite" \
    "SELECT count(*) FROM \"user\";" \
    2>/dev/null || echo 0)

  # ── تحقق من وجود الـ credentials ──
  _creds=$(sqlite3 "$N8N_DIR/database.sqlite" \
    "SELECT count(*) FROM credentials_entity;" \
    2>/dev/null || echo 0)

  # ── تحقق من وجود الـ workflows ──
  _wf=$(sqlite3 "$N8N_DIR/database.sqlite" \
    "SELECT count(*) FROM workflow_entity;" \
    2>/dev/null || echo 0)

  echo ""
  echo "✅ DB جاهزة!"
  echo "   📋 جداول: $_tc"
  echo "   👤 مستخدمين: $_users"
  echo "   🔑 credentials: $_creds"
  echo "   ⚙️ workflows: $_wf"

  # حفظ محلياً
  cp "$_mfile" "$HIST/${_bid}.json" 2>/dev/null || true

  rm -rf "$TMP/db"
  echo ""
  echo "🎉 اكتمل: $_bid"
  return 0
}

# ════════════════════════════
# طريقة 1: رسالة مثبّتة
# ════════════════════════════
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
  if dl_file "$_pin_fid" "$TMP/manifest.json"; then
    if restore_from_manifest "$TMP/manifest.json"; then
      exit 0
    fi
    echo "  ⚠️ فشل - نجرب طريقة أخرى"
  fi
else
  echo "  📭 لا يوجد مانيفست مثبّت"
fi

# ════════════════════════════
# طريقة 2: رسائل القناة
# ════════════════════════════
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
  if dl_file "$_fid2" "$TMP/manifest2.json"; then
    if restore_from_manifest "$TMP/manifest2.json"; then
      exit 0
    fi
  fi
else
  echo "  📭 لا يوجد في الرسائل"
fi

# ════════════════════════════
# طريقة 3: السجل المحلي
# ════════════════════════════
echo ""
echo "🔍 [3/3] السجل المحلي..."

_local=$(ls -t "$HIST"/*.json 2>/dev/null | head -1 || true)
if [ -n "$_local" ] && [ -f "$_local" ]; then
  echo "  📂 $(basename "$_local")"
  if restore_from_manifest "$_local"; then
    exit 0
  fi
else
  echo "  📭 لا يوجد"
fi

echo ""
echo "📭 لا توجد نسخة - n8n سيبدأ جديد"
exit 0
