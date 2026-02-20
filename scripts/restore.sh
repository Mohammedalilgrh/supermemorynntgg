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

# ── تحميل ملف بـ file_id ──
dl_file() {
  _fid="$1"
  _out="$2"
  _max_try="${3:-3}"
  _try=0

  while [ "$_try" -lt "$_max_try" ]; do
    _resp=$(curl -sS --max-time 15 \
      "${TG}/getFile?file_id=${_fid}" 2>/dev/null || true)
    _path=$(echo "$_resp" | jq -r '.result.file_path // empty' 2>/dev/null || true)

    if [ -n "$_path" ]; then
      if curl -sS --max-time 120 -o "$_out" \
        "https://api.telegram.org/file/bot${TG_BOT_TOKEN}/${_path}" \
        2>/dev/null; then
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

  # تحقق من صحة JSON
  if ! jq empty "$_mfile" 2>/dev/null; then
    echo "  ❌ المانيفست تالف أو غير صالح"
    return 1
  fi

  _bid=$(jq -r '.id // "unknown"' "$_mfile" 2>/dev/null || echo "unknown")
  _bfc=$(jq -r '.file_count // 0' "$_mfile" 2>/dev/null || echo "0")
  _bdb=$(jq -r '.db_size // "?"' "$_mfile" 2>/dev/null || echo "?")

  echo "  📋 باك أب: $_bid"
  echo "  📦 ملفات: $_bfc | DB: $_bdb"

  _rdir="$TMP/data_restore"
  rm -rf "$_rdir"
  mkdir -p "$_rdir"

  # تحميل كل الملفات
  _dl_failed=false

  # استخراج قائمة الملفات من المانيفست
  _files_json=$(jq -r '.files[] | "\(.file_id)|\(.name)"' "$_mfile" 2>/dev/null || true)

  if [ -z "$_files_json" ]; then
    echo "  ❌ لا توجد ملفات في المانيفست"
    rm -rf "$_rdir"
    return 1
  fi

  echo "$_files_json" | while IFS='|' read -r _fid _fn; do
    [ -n "$_fid" ] && [ -n "$_fn" ] || continue
    echo "    📥 تحميل: $_fn"

    if dl_file "$_fid" "$_rdir/$_fn" 3; then
      _sz=$(du -h "$_rdir/$_fn" 2>/dev/null | cut -f1 || echo "?")
      echo "      ✅ $_fn ($_sz)"
    else
      echo "      ❌ فشل تحميل: $_fn"
      touch "$_rdir/.dl_failed"
    fi
    sleep 1
  done

  # تحقق من فشل التحميل
  if [ -f "$_rdir/.dl_failed" ]; then
    echo "  ❌ فشل تحميل بعض الملفات"
    rm -rf "$_rdir"
    return 1
  fi

  # تحقق أن هناك ملفات فعلاً
  _dl_count=$(find "$_rdir" -type f ! -name '.dl_failed' 2>/dev/null | wc -l || echo 0)
  if [ "$_dl_count" -eq 0 ]; then
    echo "  ❌ لم يتم تحميل أي ملفات"
    rm -rf "$_rdir"
    return 1
  fi

  echo "  ✅ تم تحميل $_dl_count ملفات"

  # ── استرجاع DB ──
  echo "  🗄️ استرجاع قاعدة البيانات..."
  _db_ok=false

  # تحقق من وجود أجزاء أو ملف كامل
  _part_count=$(ls -1 "$_rdir"/db.sql.gz.part_* 2>/dev/null | wc -l || echo 0)

  if [ "$_part_count" -gt 0 ]; then
    echo "    📦 دمج $_part_count أجزاء..."
    _parts_sorted=$(ls -v "$_rdir"/db.sql.gz.part_* 2>/dev/null || true)
    if cat $_parts_sorted | gzip -dc | sqlite3 "$N8N_DIR/database.sqlite" 2>/dev/null; then
      _db_ok=true
    fi
  elif [ -f "$_rdir/db.sql.gz" ]; then
    echo "    📦 استرجاع ملف كامل..."
    if gzip -dc "$_rdir/db.sql.gz" | sqlite3 "$N8N_DIR/database.sqlite" 2>/dev/null; then
      _db_ok=true
    fi
  else
    echo "  ❌ لا توجد ملفات DB في النسخة"
    rm -rf "$_rdir"
    return 1
  fi

  # تحقق من صحة DB
  if [ "$_db_ok" = "false" ] || [ ! -s "$N8N_DIR/database.sqlite" ]; then
    echo "  ❌ فشل بناء قاعدة البيانات"
    rm -f "$N8N_DIR/database.sqlite" 2>/dev/null || true
    rm -rf "$_rdir"
    return 1
  fi

  _tc=$(sqlite3 "$N8N_DIR/database.sqlite" \
    "SELECT count(*) FROM sqlite_master WHERE type='table';" \
    2>/dev/null || echo 0)

  if [ "$_tc" -eq 0 ]; then
    echo "  ❌ قاعدة البيانات فارغة أو تالفة"
    rm -f "$N8N_DIR/database.sqlite" 2>/dev/null || true
    rm -rf "$_rdir"
    return 1
  fi

  echo "  ✅ قاعدة البيانات جاهزة - $_tc جدول"

  # ── استرجاع ملفات الإعدادات ──
  echo "  📁 استرجاع ملفات الإعدادات..."

  _fpart_count=$(ls -1 "$_rdir"/files.tar.gz.part_* 2>/dev/null | wc -l || echo 0)

  if [ "$_fpart_count" -gt 0 ]; then
    _fparts_sorted=$(ls -v "$_rdir"/files.tar.gz.part_* 2>/dev/null || true)
    cat $_fparts_sorted | gzip -dc | \
      tar -C "$N8N_DIR" -xf - 2>/dev/null || true
    echo "  ✅ ملفات الإعدادات مسترجعة (أجزاء)"
  elif [ -f "$_rdir/files.tar.gz" ]; then
    gzip -dc "$_rdir/files.tar.gz" | \
      tar -C "$N8N_DIR" -xf - 2>/dev/null || true
    echo "  ✅ ملفات الإعدادات مسترجعة"
  else
    echo "  ℹ️ لا توجد ملفات إعدادات (سيستخدم الافتراضي)"
  fi

  # حفظ المانيفست محلياً للسجل
  cp "$_mfile" "$HIST/${_bid}.json" 2>/dev/null || true

  rm -rf "$_rdir"

  echo ""
  echo "  🎉 الاسترجاع اكتمل بنجاح!"
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
  if dl_file "$_pin_fid" "$TMP/manifest_pin.json" 3; then
    if restore_from_manifest "$TMP/manifest_pin.json"; then
      exit 0
    fi
    echo "  ⚠️ فشل الاسترجاع من المانيفست المثبّت"
  else
    echo "  ⚠️ فشل تحميل المانيفست المثبّت"
  fi
else
  echo "  📭 لا يوجد مانيفست مثبّت"
fi

# ════════════════════════════════
# الطريقة 2: آخر رسائل القناة
# ════════════════════════════════
echo ""
echo "🔍 [2/3] البحث في رسائل القناة..."

_updates=$(curl -sS --max-time 20 \
  "${TG}/getUpdates?offset=-100&limit=100" 2>/dev/null || true)

if [ -n "$_updates" ]; then
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
    echo "  📋 وجدنا مانيفست في رسائل القناة!"
    if dl_file "$_found_fid" "$TMP/manifest_search.json" 3; then
      if restore_from_manifest "$TMP/manifest_search.json"; then
        exit 0
      fi
    fi
  else
    echo "  📭 لم نجد مانيفست في الرسائل"
  fi
fi

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
  echo "  ⚠️ فشل الاسترجاع من السجل المحلي"
else
  echo "  📭 لا يوجد سجل محلي"
fi

echo ""
echo "📭 لا توجد نسخة احتياطية - سيبدأ n8n من جديد"
exit 0
