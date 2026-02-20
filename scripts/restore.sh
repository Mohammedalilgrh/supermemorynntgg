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

[ -s "$N8N_DIR/database.sqlite" ] && { echo "✅ DB موجودة - لا حاجة للاسترجاع"; exit 0; }

echo "=== 🔍 البحث عن آخر باك أب في Telegram ==="

# ── تحميل ملف بـ file_id ──
dl_file() {
  _fid="$1"
  _out="$2"
  _max_try="${3:-3}"
  _try=0

  while [ "$_try" -lt "$_max_try" ]; do
    _path=$(curl -sS --max-time 15 "${TG}/getFile?file_id=${_fid}" \
      | jq -r '.result.file_path // empty' 2>/dev/null || true)

    if [ -n "$_path" ]; then
      if curl -sS --max-time 120 -o "$_out" \
        "https://api.telegram.org/file/bot${TG_BOT_TOKEN}/${_path}" 2>/dev/null; then
        [ -s "$_out" ] && return 0
      fi
    fi

    _try=$((_try + 1))
    echo "    ⚠️ إعادة المحاولة $_try/$_max_try..."
    sleep 3
  done
  return 1
}

# ── استرجاع من مانيفست ──
restore_from_manifest() {
  _mfile="$1"

  # تحقق من صحة الـ JSON
  jq empty "$_mfile" 2>/dev/null || { echo "  ❌ المانيفست تالف"; return 1; }

  _bid=$(jq -r '.id // "?"' "$_mfile")
  _bfc=$(jq -r '.file_count // 0' "$_mfile")
  echo "  📋 باك أب: $_bid ($bfc ملفات)"

  _rdir="$TMP/data_$$"
  rm -rf "$_rdir"
  mkdir -p "$_rdir"

  # تحميل كل الملفات
  _dl_ok=true
  while IFS='|' read -r _fid _fn; do
    [ -n "$_fid" ] && [ -n "$_fn" ] || continue
    echo "    📥 $_fn..."

    if dl_file "$_fid" "$_rdir/$_fn" 3; then
      _sz=$(du -h "$_rdir/$_fn" | cut -f1)
      echo "      ✅ $_fn ($_sz)"
    else
      echo "      ❌ فشل تحميل $_fn"
      _dl_ok=false
    fi
    sleep 1
  done << EOF
$(jq -r '.files[] | "\(.file_id)|\(.name)"' "$_mfile" 2>/dev/null)
EOF

  if [ "$_dl_ok" = "false" ]; then
    echo "  ❌ فشل تحميل بعض الملفات"
    rm -rf "$_rdir"
    return 1
  fi

  # ── استرجاع DB ──
  echo "  🗄️ استرجاع قاعدة البيانات..."
  _db_restored=false

  if ls "$_rdir"/db.sql.gz.part_* >/dev/null 2>&1; then
    echo "    📦 دمج الأجزاء..."
    if cat $(ls -v "$_rdir"/db.sql.gz.part_*) | \
       gzip -dc | \
       sqlite3 "$N8N_DIR/database.sqlite" 2>/dev/null; then
      _db_restored=true
    fi
  elif [ -f "$_rdir/db.sql.gz" ]; then
    if gzip -dc "$_rdir/db.sql.gz" | \
       sqlite3 "$N8N_DIR/database.sqlite" 2>/dev/null; then
      _db_restored=true
    fi
  else
    echo "  ❌ لا توجد ملفات DB"
    rm -rf "$_rdir"
    return 1
  fi

  if [ "$_db_restored" = "false" ] || [ ! -s "$N8N_DIR/database.sqlite" ]; then
    echo "  ❌ فشل استرجاع DB"
    rm -f "$N8N_DIR/database.sqlite" 2>/dev/null || true
    rm -rf "$_rdir"
    return 1
  fi

  # تحقق من صحة DB
  _tc=$(sqlite3 "$N8N_DIR/database.sqlite" \
    "SELECT count(*) FROM sqlite_master WHERE type='table';" 2>/dev/null || echo 0)

  if [ "$_tc" -eq 0 ]; then
    echo "  ❌ DB فارغة أو تالفة"
    rm -f "$N8N_DIR/database.sqlite" 2>/dev/null || true
    rm -rf "$_rdir"
    return 1
  fi
  echo "  ✅ DB جاهزة - $_tc جدول"

  # ── استرجاع الملفات ──
  echo "  📁 استرجاع ملفات n8n..."

  if ls "$_rdir"/files.tar.gz.part_* >/dev/null 2>&1; then
    cat $(ls -v "$_rdir"/files.tar.gz.part_*) | \
      gzip -dc | \
      tar -C "$N8N_DIR" -xf - 2>/dev/null || true
    echo "  ✅ ملفات الإعدادات مسترجعة"
  elif [ -f "$_rdir/files.tar.gz" ]; then
    gzip -dc "$_rdir/files.tar.gz" | \
      tar -C "$N8N_DIR" -xf - 2>/dev/null || true
    echo "  ✅ ملفات الإعدادات مسترجعة"
  fi

  # حفظ المانيفست محلياً
  cp "$_mfile" "$HIST/${_bid}.json" 2>/dev/null || true

  rm -rf "$_rdir"
  echo ""
  echo "  🎉 الاسترجاع اكتمل بنجاح!"
  echo "  🆔 $_bid | 📋 $_tc جدول"
  return 0
}

# ════════════════════════════════
# الطريقة 1: الرسالة المثبّتة في القناة
# ════════════════════════════════
echo ""
echo "🔍 [1/3] البحث في الرسالة المثبّتة..."

_chat_info=$(curl -sS --max-time 15 "${TG}/getChat?chat_id=${TG_CHAT_ID}" 2>/dev/null || true)
_pin_fid=$(echo "$_chat_info" | jq -r '.result.pinned_message.document.file_id // empty' 2>/dev/null || true)
_pin_cap=$(echo "$_chat_info" | jq -r '.result.pinned_message.caption // ""' 2>/dev/null || true)

if [ -n "$_pin_fid" ] && echo "$_pin_cap" | grep -q "n8n_manifest"; then
  echo "  📌 وجدنا مانيفست مثبّت!"
  if dl_file "$_pin_fid" "$TMP/manifest_pin.json" 3; then
    if restore_from_manifest "$TMP/manifest_pin.json"; then
      exit 0
    fi
    echo "  ⚠️ فشل الاسترجاع من المانيفست المثبّت - جرب طريقة أخرى"
  fi
fi
echo "  📭 لا يوجد مانيفست مثبّت"

# ════════════════════════════════
# الطريقة 2: آخر رسائل القناة
# ════════════════════════════════
echo ""
echo "🔍 [2/3] البحث في رسائل القناة..."

# نجرب بـ offset سالب للحصول على آخر الرسائل
for _limit in 100; do
  _updates=$(curl -sS --max-time 20 \
    "${TG}/getUpdates?offset=-${_limit}&limit=${_limit}" 2>/dev/null || true)

  _found_fid=$(echo "$_updates" | jq -r '
    [
      .result[] |
      select(
        (.channel_post.document != null) and
        ((.channel_post.caption // "") | contains("n8n_manifest"))
      )
    ] |
    sort_by(-.channel_post.date) |
    .[0].channel_post.document.file_id // empty
  ' 2>/dev/null || true)

  if [ -n "$_found_fid" ]; then
    echo "  📋 وجدنا مانيفست في الرسائل!"
    if dl_file "$_found_fid" "$TMP/manifest_search.json" 3; then
      if restore_from_manifest "$TMP/manifest_search.json"; then
        exit 0
      fi
    fi
    break
  fi
done

echo "  📭 لم نجد مانيفست في الرسائل"

# ════════════════════════════════
# الطريقة 3: السجل المحلي
# ════════════════════════════════
echo ""
echo "🔍 [3/3] البحث في السجل المحلي..."

_local_latest=$(ls -t "$HIST"/*.json 2>/dev/null | head -1 || true)
if [ -n "$_local_latest" ] && [ -f "$_local_latest" ]; then
  echo "  📂 وجدنا سجل محلي: $(basename "$_local_latest")"
  if restore_from_manifest "$_local_latest"; then
    exit 0
  fi
fi
echo "  📭 لا يوجد سجل محلي"

echo ""
echo "📭 لا توجد نسخة احتياطية للاسترجاع - سيبدأ n8n من جديد"
exit 0
