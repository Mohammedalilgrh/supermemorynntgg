#!/bin/sh
set -eu
umask 077

: "${TG_BOT_TOKEN:?}" "${TG_CHAT_ID:?}"

N8N_DIR="${N8N_DIR:-/home/node/.n8n}"
WORK="${WORK:-/backup-data}"
HIST="$WORK/history"

TG="https://api.telegram.org/bot${TG_BOT_TOKEN}"
TMP="/tmp/restore_$$"

trap 'rm -rf "$TMP"' EXIT
mkdir -p "$N8N_DIR" "$WORK" "$HIST" "$TMP"

# لو الداتابيس موجودة = لا تسترجع
[ -s "$N8N_DIR/database.sqlite" ] && { echo "✅ الداتابيس موجودة"; exit 0; }

echo "🔍 البحث عن نسخة احتياطية..."

# ── تحميل ملف من تلكرام ──
download_file() {
  _fid="$1"
  _output="$2"

  _path=$(curl -sS "${TG}/getFile?file_id=${_fid}" 2>/dev/null \
    | jq -r '.result.file_path // empty' 2>/dev/null)

  [ -n "$_path" ] || return 1

  curl -sS -o "$_output" \
    "https://api.telegram.org/file/bot${TG_BOT_TOKEN}/${_path}"

  [ -s "$_output" ]
}

# ── تحميل ذكي (يدعم تغيير البوت) ──
smart_download() {
  _fid="$1"
  _mid="$2"
  _output="$3"

  # محاولة 1: بالـ file_id مباشرة
  if download_file "$_fid" "$_output" 2>/dev/null; then
    return 0
  fi

  echo "      ⚠️ file_id ما اشتغل، نجرب message_id..."

  # محاولة 2: forward الرسالة → file_id جديد
  if [ -n "$_mid" ] && [ "$_mid" != "null" ] && [ "$_mid" != "0" ]; then
    _fwd=$(curl -sS -X POST "${TG}/forwardMessage" \
      -d "chat_id=${TG_CHAT_ID}" \
      -d "from_chat_id=${TG_CHAT_ID}" \
      -d "message_id=${_mid}" 2>/dev/null || true)

    _new_fid=$(echo "$_fwd" | jq -r '.result.document.file_id // empty' 2>/dev/null)
    _fwd_mid=$(echo "$_fwd" | jq -r '.result.message_id // empty' 2>/dev/null)

    # حذف الفورورد
    [ -n "$_fwd_mid" ] && curl -sS -X POST "${TG}/deleteMessage" \
      -d "chat_id=${TG_CHAT_ID}" \
      -d "message_id=${_fwd_mid}" >/dev/null 2>&1 || true

    if [ -n "$_new_fid" ]; then
      echo "      ✅ حصلنا file_id جديد!"
      if download_file "$_new_fid" "$_output" 2>/dev/null; then
        return 0
      fi
    fi
  fi

  return 1
}

# ── استرجاع من مانيفست ──
restore_from_manifest() {
  _manifest="$1"
  _bid=$(jq -r '.id // "?"' "$_manifest" 2>/dev/null)
  echo "  📋 استرجاع نسخة: $_bid"

  _restore_dir="$TMP/files"
  rm -rf "$_restore_dir"
  mkdir -p "$_restore_dir"

  # تحميل كل الملفات
  jq -r '.files[] | "\(.file_id)|\(.name)|\(.message_id // 0)"' \
    "$_manifest" 2>/dev/null | \
  while IFS='|' read -r _fid _fname _mid; do
    [ -n "$_fid" ] || continue
    echo "    📥 $_fname"

    _retry=0
    _downloaded=""

    while [ "$_retry" -lt 3 ]; do
      if smart_download "$_fid" "$_mid" "$_restore_dir/$_fname"; then
        _downloaded="yes"
        break
      fi
      _retry=$((_retry + 1))
      sleep 2
    done

    if [ -z "$_downloaded" ]; then
      echo "FAIL" > "$_restore_dir/.fail"
      echo "    ❌ فشل: $_fname"
    fi

    sleep 1
  done

  # فحص الفشل
  if [ -f "$_restore_dir/.fail" ]; then
    echo "  ❌ فشل تحميل بعض الملفات"
    return 1
  fi

  # ── تجميع واسترجاع DB ──
  if ls "$_restore_dir"/db.sql.gz.part_* >/dev/null 2>&1; then
    echo "  🔧 تجميع أجزاء الداتابيس..."
    cat "$_restore_dir"/db.sql.gz.part_* | gzip -dc \
      | sqlite3 "$N8N_DIR/database.sqlite"
  elif [ -f "$_restore_dir/db.sql.gz" ]; then
    echo "  🔧 استرجاع الداتابيس..."
    gzip -dc "$_restore_dir/db.sql.gz" \
      | sqlite3 "$N8N_DIR/database.sqlite"
  else
    echo "  ❌ لا توجد داتابيس بالنسخة"
    return 1
  fi

  # فحص الداتابيس
  if [ ! -s "$N8N_DIR/database.sqlite" ]; then
    echo "  ❌ الداتابيس فارغة"
    rm -f "$N8N_DIR/database.sqlite"
    return 1
  fi

  _tables=$(sqlite3 "$N8N_DIR/database.sqlite" \
    "SELECT count(*) FROM sqlite_master WHERE type='table';" \
    2>/dev/null || echo 0)

  if [ "$_tables" -eq 0 ]; then
    echo "  ❌ لا جداول بالداتابيس"
    rm -f "$N8N_DIR/database.sqlite"
    return 1
  fi

  echo "  ✅ $_tables جدول"

  # ── استرجاع الملفات الإضافية ──
  if ls "$_restore_dir"/files.tar.gz.part_* >/dev/null 2>&1; then
    echo "  🔧 تجميع الملفات..."
    cat "$_restore_dir"/files.tar.gz.part_* | gzip -dc \
      | tar -C "$N8N_DIR" -xf - 2>/dev/null || true
  elif [ -f "$_restore_dir/files.tar.gz" ]; then
    echo "  🔧 استرجاع الملفات..."
    gzip -dc "$_restore_dir/files.tar.gz" \
      | tar -C "$N8N_DIR" -xf - 2>/dev/null || true
  fi

  # حفظ المانيفست محلياً
  cp "$_manifest" "$HIST/${_bid}.json" 2>/dev/null || true

  rm -rf "$_restore_dir"
  echo "  🎉 تم الاسترجاع بنجاح!"
  return 0
}

# ═══════════════════════════════════════
# الطريقة 1: الرسالة المثبّتة
# ═══════════════════════════════════════
echo "🔍 [1] الرسالة المثبّتة..."

PIN_RESPONSE=$(curl -sS "${TG}/getChat?chat_id=${TG_CHAT_ID}" 2>/dev/null)

_pin_fid=$(echo "$PIN_RESPONSE" \
  | jq -r '.result.pinned_message.document.file_id // empty' 2>/dev/null)
_pin_caption=$(echo "$PIN_RESPONSE" \
  | jq -r '.result.pinned_message.caption // ""' 2>/dev/null)

if [ -n "$_pin_fid" ] && echo "$_pin_caption" | grep -q "n8n_manifest"; then
  echo "  📌 لقينا رسالة مثبّتة!"
  if download_file "$_pin_fid" "$TMP/manifest.json"; then
    restore_from_manifest "$TMP/manifest.json" && exit 0
  fi
fi

# ═══════════════════════════════════════
# الطريقة 2: آخر الرسائل
# ═══════════════════════════════════════
echo "🔍 [2] آخر الرسائل..."

UPDATES=$(curl -sS "${TG}/getUpdates?offset=-100&limit=100" 2>/dev/null || true)

if [ -n "$UPDATES" ]; then
  _update_fid=$(echo "$UPDATES" | jq -r '
    [.result[] | select(
      (.channel_post.document != null) and
      ((.channel_post.caption // "") | contains("n8n_manifest"))
    )] | sort_by(-.channel_post.date)
    | .[0].channel_post.document.file_id // empty
  ' 2>/dev/null || true)

  if [ -n "$_update_fid" ]; then
    echo "  📋 لقينا بالرسائل!"
    if download_file "$_update_fid" "$TMP/manifest2.json"; then
      restore_from_manifest "$TMP/manifest2.json" && exit 0
    fi
  fi
fi

echo "📭 لا توجد نسخة احتياطية"
exit 1
