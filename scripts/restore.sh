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

echo "🔍 البحث..."

# ── دالة التحميل ──
dl() {
  # نحاول نجيب مسار الملف
  p=$(curl -sS "${TG}/getFile?file_id=$1" | jq -r '.result.file_path // empty' 2>/dev/null)
  [ -n "$p" ] || return 1
  curl -sS -o "$2" "https://api.telegram.org/file/bot${TG_BOT_TOKEN}/${p}"
  [ -s "$2" ]
}

# ── دالة الاسترجاع الذكية (تفهم القديم والجديد) ──
do_r() {
  mf="$1"
  bid=$(jq -r '.id // "?"' "$mf" 2>/dev/null)
  echo "  📋 استرجاع النسخة: $bid"

  rd="$TMP/d"; rm -rf "$rd"; mkdir -p "$rd"

  # هنا الذكاء: نقرأ الصيغة الجديدة (.f, .n) وإذا ماكو نقرأ القديمة (.file_id, .name)
  jq -r '.files[] | "\(.f // .file_id)|\(.n // .name)"' "$mf" 2>/dev/null | \
  while IFS='|' read -r fid fn; do
    [ -n "$fid" ] || continue
    echo "    📥 تحميل: $fn"
    t=0
    while [ "$t" -lt 3 ]; do
      dl "$fid" "$rd/$fn" && break
      t=$((t+1)); sleep 2
    done
    [ -s "$rd/$fn" ] || echo "FAIL" > "$rd/.fail"
    sleep 1
  done

  [ ! -f "$rd/.fail" ] || { echo "  ❌ فشل تحميل الملفات"; return 1; }

  # ── استرجاع الداتابيس (يدعم القديم والجديد) ──
  echo "  🗄️ فك ضغط الداتابيس..."
  
  # 1. النسخة الجديدة (d.gz)
  if ls "$rd"/d.gz.p* >/dev/null 2>&1; then
    cat "$rd"/d.gz.p* | gzip -dc | sqlite3 "$D/database.sqlite"
  elif [ -f "$rd/d.gz" ]; then
    gzip -dc "$rd/d.gz" | sqlite3 "$D/database.sqlite"
  
  # 2. النسخة القديمة (db.sql.gz)
  elif ls "$rd"/db.sql.gz.part_* >/dev/null 2>&1; then
    cat "$rd"/db.sql.gz.part_* | gzip -dc | sqlite3 "$D/database.sqlite"
  elif [ -f "$rd/db.sql.gz" ]; then
    gzip -dc "$rd/db.sql.gz" | sqlite3 "$D/database.sqlite"
  
  else
    echo "  ❌ لم يتم العثور على ملف داتابيس"; return 1
  fi

  [ -s "$D/database.sqlite" ] || { echo "  ❌ الداتابيس فارغة"; rm -f "$D/database.sqlite"; return 1; }

  tc=$(sqlite3 "$D/database.sqlite" "SELECT count(*) FROM sqlite_master WHERE type='table';" 2>/dev/null || echo 0)
  [ "$tc" -gt 0 ] || { rm -f "$D/database.sqlite"; return 1; }
  echo "  ✅ تم استرجاع $tc جدول"

  # ── استرجاع الملفات (يدعم القديم والجديد) ──
  echo "  📁 فك ضغط الملفات..."
  
  # 1. النسخة الجديدة (f.gz)
  if ls "$rd"/f.gz.p* >/dev/null 2>&1; then
    cat "$rd"/f.gz.p* | gzip -dc | tar -C "$D" -xf - 2>/dev/null || true
  elif [ -f "$rd/f.gz" ]; then
    gzip -dc "$rd/f.gz" | tar -C "$D" -xf - 2>/dev/null || true
  
  # 2. النسخة القديمة (files.tar.gz)
  elif ls "$rd"/files.tar.gz.part_* >/dev/null 2>&1; then
    cat "$rd"/files.tar.gz.part_* | gzip -dc | tar -C "$D" -xf - 2>/dev/null || true
  elif [ -f "$rd/files.tar.gz" ]; then
    gzip -dc "$rd/files.tar.gz" | tar -C "$D" -xf - 2>/dev/null || true
  fi

  # نحفظ المانيفست بالتاريخ
  cp "$mf" "$H/${bid}.json" 2>/dev/null || true
  
  rm -rf "$rd"
  echo "  🎉 تم الاسترجاع بنجاح!"
  return 0
}

# ═══ البحث 1: الرسالة المثبّتة ═══
echo "🔍 [1] فحص الرسالة المثبّتة..."
PIN=$(curl -sS "${TG}/getChat?chat_id=${TG_CHAT_ID}" 2>/dev/null)
pfid=$(echo "$PIN" | jq -r '.result.pinned_message.document.file_id // empty' 2>/dev/null)
pcap=$(echo "$PIN" | jq -r '.result.pinned_message.caption // ""' 2>/dev/null)

if [ -n "$pfid" ] && echo "$pcap" | grep -q "n8n_manifest"; then
  echo "  📌 وجدنا مانيفست مثبّت!"
  if dl "$pfid" "$TMP/m.json"; then
    do_r "$TMP/m.json" && exit 0
  fi
fi

# ═══ البحث 2: البحث في القناة ═══
echo "🔍 [2] البحث في آخر الرسائل..."
UPD=$(curl -sS "${TG}/getUpdates?offset=-100&limit=100" 2>/dev/null || true)

if [ -n "$UPD" ]; then
  ufid=$(echo "$UPD" | jq -r '
    [.result[] | select(
      (.channel_post.document != null) and
      ((.channel_post.caption // "") | contains("n8n_manifest"))
    )] | sort_by(-.channel_post.date) | .[0].channel_post.document.file_id // empty
  ' 2>/dev/null || true)

  if [ -n "$ufid" ]; then
    echo "  📋 وجدنا مانيفست حديث!"
    if dl "$ufid" "$TMP/m2.json"; then
      do_r "$TMP/m2.json" && exit 0
    fi
  fi
fi

echo "📭 لم يتم العثور على نسخة احتياطية (سيبدأ كجديد)"
exit 1
