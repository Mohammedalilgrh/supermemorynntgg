#!/bin/sh
set -eu
umask 077

: "${TG_BOT_TOKEN:?}" "${TG_CHAT_ID:?}"

D="${N8N_DIR:-/home/node/.n8n}"
W="${WORK:-/backup-data}"
H="$W/h"

TG="https://api.telegram.org/bot${TG_BOT_TOKEN}"
TMP="/tmp/r$$"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$D" "$W" "$H" "$TMP"

[ -s "$D/database.sqlite" ] && { echo "✅ موجودة"; exit 0; }

echo "🔍 البحث عن باك أب..."

# ── تحميل ملف ──
dl() {
  p=$(curl -sS "${TG}/getFile?file_id=$1" 2>/dev/null | jq -r '.result.file_path // empty' 2>/dev/null)
  [ -n "$p" ] || return 1
  curl -sS -o "$2" "https://api.telegram.org/file/bot${TG_BOT_TOKEN}/${p}" 2>/dev/null
  [ -s "$2" ]
}

# ── استرجاع من مانيفست (يدعم الصيغتين) ──
do_r() {
  mf="$1"
  
  # دعم الصيغة الجديدة (مضغوطة)
  bid=$(jq -r '.id // .ID // "?"' "$mf" 2>/dev/null)
  echo "  📋 النسخة: $bid"

  rd="$TMP/d"; rm -rf "$rd"; mkdir -p "$rd"

  # تحميل كل الملفات (يدعم الأسماء القديمة والجديدة)
  fail=""
  jq -r '.files[] | "\(.f // .file_id)|\(.n // .name)"' "$mf" 2>/dev/null | \
  while IFS='|' read -r fid fn; do
    [ -n "$fid" ] || continue
    echo "    📥 $fn"
    t=0
    while [ "$t" -lt 3 ]; do
      dl "$fid" "$rd/$fn" && break
      t=$((t+1)); sleep 2
    done
    [ -s "$rd/$fn" ] || echo "FAIL" > "$rd/.fail"
    sleep 1
  done

  [ ! -f "$rd/.fail" ] || { echo "  ❌ فشل التحميل"; return 1; }

  # تجميع DB (يدعم الأسماء القديمة والجديدة)
  if ls "$rd"/d.gz.p* >/dev/null 2>&1; then
    cat "$rd"/d.gz.p* | gzip -dc | sqlite3 "$D/database.sqlite"
  elif ls "$rd"/db.sql.gz.part_* >/dev/null 2>&1; then
    # الصيغة القديمة
    cat "$rd"/db.sql.gz.part_* | gzip -dc | sqlite3 "$D/database.sqlite"
  elif [ -f "$rd/d.gz" ]; then
    gzip -dc "$rd/d.gz" | sqlite3 "$D/database.sqlite"
  elif [ -f "$rd/db.sql.gz" ]; then
    # الصيغة القديمة
    gzip -dc "$rd/db.sql.gz" | sqlite3 "$D/database.sqlite"
  else
    echo "  ❌ لا توجد ملفات داتابيس"; return 1
  fi

  [ -s "$D/database.sqlite" ] || { echo "  ❌ الداتابيس فارغة"; rm -f "$D/database.sqlite"; return 1; }

  tc=$(sqlite3 "$D/database.sqlite" "SELECT count(*) FROM sqlite_master WHERE type='table';" 2>/dev/null || echo 0)
  [ "$tc" -gt 0 ] || { rm -f "$D/database.sqlite"; return 1; }
  echo "  ✅ $tc جدول"

  # ملفات إضافية (يدعم الأسماء القديمة والجديدة)
  if ls "$rd"/f.gz.p* >/dev/null 2>&1; then
    cat "$rd"/f.gz.p* | gzip -dc | tar -C "$D" -xf - 2>/dev/null || true
  elif ls "$rd"/files.tar.gz.part_* >/dev/null 2>&1; then
    # الصيغة القديمة
    cat "$rd"/files.tar.gz.part_* | gzip -dc | tar -C "$D" -xf - 2>/dev/null || true
  elif [ -f "$rd/f.gz" ]; then
    gzip -dc "$rd/f.gz" | tar -C "$D" -xf - 2>/dev/null || true
  elif [ -f "$rd/files.tar.gz" ]; then
    # الصيغة القديمة
    gzip -dc "$rd/files.tar.gz" | tar -C "$D" -xf - 2>/dev/null || true
  fi

  # حفظ المانيفست بالتاريخ (للبوت الجديد)
  bid_clean=$(echo "$bid" | tr -d '[:space:]')
  cp "$mf" "$H/${bid_clean}.json" 2>/dev/null || true
  
  rm -rf "$rd"
  echo "  🎉 تم الاسترجاع!"
  return 0
}

# ═══ الطريقة 1: الرسالة المثبّتة ═══
echo "🔍 [1/3] الرسالة المثبّتة..."
PIN=$(curl -sS "${TG}/getChat?chat_id=${TG_CHAT_ID}" 2>/dev/null)
pfid=$(echo "$PIN" | jq -r '.result.pinned_message.document.file_id // empty' 2>/dev/null)
pcap=$(echo "$PIN" | jq -r '.result.pinned_message.caption // ""' 2>/dev/null)

if [ -n "$pfid" ] && echo "$pcap" | grep -qi "manifest"; then
  echo "  📌 لقينا مانيفست!"
  if dl "$pfid" "$TMP/m.json"; then
    do_r "$TMP/m.json" && exit 0
  fi
fi

# ═══ الطريقة 2: getUpdates (آخر 100 رسالة) ═══
echo "🔍 [2/3] آخر الرسائل..."
UPD=$(curl -sS "${TG}/getUpdates?offset=-100&limit=100" 2>/dev/null || true)

if [ -n "$UPD" ]; then
  # نبحث عن أي مانيفست (قديم أو جديد)
  ufid=$(echo "$UPD" | jq -r '
    [.result[] | select(
      (.channel_post.document != null or .message.document != null) and
      ((.channel_post.caption // .message.caption // "") | test("manifest"; "i"))
    )] | sort_by(-(.channel_post.date // .message.date)) | .[0].document.file_id // empty
  ' 2>/dev/null || true)

  if [ -n "$ufid" ]; then
    echo "  📋 لقينا مانيفست بالرسائل!"
    if dl "$ufid" "$TMP/m2.json"; then
      do_r "$TMP/m2.json" && exit 0
    fi
  fi
fi

# ═══ الطريقة 3: بحث عن ملفات DB مباشرة ═══
echo "🔍 [3/3] بحث عن ملفات داتابيس..."

if [ -n "$UPD" ]; then
  dfid=$(echo "$UPD" | jq -r '
    [.result[] | select(
      (.channel_post.document != null or .message.document != null) and
      ((.channel_post.document.file_name // .message.document.file_name // "") | test("db.sql.gz|d.gz"; "i"))
    )] | sort_by(-(.channel_post.date // .message.date)) | .[0].document.file_id // empty
  ' 2>/dev/null || true)

  if [ -n "$dfid" ]; then
    echo "  📥 لقينا ملف داتابيس!"
    if dl "$dfid" "$TMP/db_direct.gz"; then
      gzip -dc "$TMP/db_direct.gz" | sqlite3 "$D/database.sqlite" 2>/dev/null || true
      if [ -s "$D/database.sqlite" ]; then
        tc=$(sqlite3 "$D/database.sqlite" "SELECT count(*) FROM sqlite_master WHERE type='table';" 2>/dev/null || echo 0)
        [ "$tc" -gt 0 ] && { echo "  ✅ $tc جدول"; echo "🎉 تم!"; exit 0; }
      fi
    fi
  fi
fi

echo ""
echo "📭 لا توجد نسخة احتياطية قابلة للاسترجاع"
echo "🆕 سيبدأ n8n كأول تشغيل"
exit 1
