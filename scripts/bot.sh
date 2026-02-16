#!/bin/sh
set -eu

: "${TG_BOT_TOKEN:?}" "${TG_CHAT_ID:?}" "${TG_ADMIN_ID:?}"

D="${N8N_DIR:-/home/node/.n8n}"
W="${WORK:-/backup-data}"
H="$W/h"

TG="https://api.telegram.org/bot${TG_BOT_TOKEN}"
OFF=0
mkdir -p "$H"

# ── إرسال ──
sm() {
  curl -sS -X POST "${TG}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "{\"chat_id\":${TG_ADMIN_ID},\"text\":\"$1\",\"parse_mode\":\"HTML\"}" \
    2>/dev/null || true
}

sk() {
  curl -sS -X POST "${TG}/sendMessage" \
    -H "Content-Type: application/json" \
    -d "{\"chat_id\":${TG_ADMIN_ID},\"text\":\"$1\",\"parse_mode\":\"HTML\",\"reply_markup\":$2}" \
    2>/dev/null || true
}

ac() {
  curl -sS -X POST "${TG}/answerCallbackQuery" \
    -d "callback_query_id=$1" -d "text=${2:-⏳}" >/dev/null 2>&1 || true
}

# ── القائمة ──
MM='{"inline_keyboard":[[{"text":"📊 الحالة","callback_data":"st"}],[{"text":"💾 حفظ الآن!","callback_data":"bk"}],[{"text":"📋 النسخ السابقة","callback_data":"ls"}],[{"text":"📥 تحميل آخر نسخة","callback_data":"dl"}],[{"text":"🗑️ تنظيف","callback_data":"cl"}],[{"text":"ℹ️ معلومات","callback_data":"in"}]]}'

menu() { sk "🤖 <b>لوحة التحكم</b>

اختار:" "$MM"; }

# ── الحالة ──
do_st() {
  db="$D/database.sqlite"
  ds="—"; dt=0; tc=0; ws="0"
  if [ -f "$db" ]; then
    ds=$(du -h "$db" 2>/dev/null | cut -f1)
    dt=$(stat -c '%Y' "$db" 2>/dev/null || echo 0)
    tc=$(sqlite3 "$db" "SELECT count(*) FROM sqlite_master WHERE type='table';" 2>/dev/null || echo 0)
  fi
  [ -f "$db-wal" ] && ws=$(du -h "$db-wal" 2>/dev/null | cut -f1)

  li="—"; lt="—"
  [ -f "$W/.bs" ] && {
    li=$(grep '^I=' "$W/.bs" 2>/dev/null | cut -d= -f2 || echo "—")
    lt=$(grep '^T=' "$W/.bs" 2>/dev/null | cut -d= -f2 || echo "—")
  }
  bn=$(ls "$H"/*.json 2>/dev/null | wc -l || echo 0)

  sk "📊 <b>حالة النظام</b>

🗄️ <b>الداتابيس:</b>
  📦 الحجم: <code>$ds</code>
  📋 جداول: <code>$tc</code>
  📝 WAL: <code>$ws</code>

💾 <b>آخر باك أب:</b>
  🆔 <code>$li</code>
  🕒 <code>$lt</code>
  📊 مجموع: <code>$bn</code> نسخة

⏰ <code>$(date -u '+%Y-%m-%d %H:%M UTC')</code>" "$MM"
}

# ── حفظ فوري ──
do_bk() {
  sm "⏳ <b>جاري الحفظ...</b>"
  rm -f "$W/.bs"
  out=$(sh /scripts/backup.sh 2>&1 || true)

  if echo "$out" | grep -q "✅"; then
    id=$(grep '^I=' "$W/.bs" 2>/dev/null | cut -d= -f2 || echo "?")
    sk "✅ <b>تم الحفظ!</b>

🆔 <code>$id</code>
🕒 <code>$(date -u '+%H:%M:%S UTC')</code>" "$MM"
  else
    sk "❌ <b>فشل</b>

<pre>$(echo "$out" | tail -3)</pre>" "$MM"
  fi
}

# ── قائمة النسخ ──
do_ls() {
  c=0; txt=""
  kb='{"inline_keyboard":['

  for f in $(ls -t "$H"/*.json 2>/dev/null | head -10); do
    [ -f "$f" ] || continue
    c=$((c+1))
    bid=$(jq -r '.id // "?"' "$f" 2>/dev/null)
    bts=$(jq -r '.ts // "?"' "$f" 2>/dev/null)
    bdb=$(jq -r '.db // "?"' "$f" 2>/dev/null)
    bfc=$(jq -r '.fc // 0' "$f" 2>/dev/null)
    bfn=$(basename "$f" .json)

    txt="${txt}
<b>${c}.</b> 🆔 <code>${bid}</code>
   📅 ${bts}
   📦 DB:${bdb} | ${bfc} ملفات
"
    [ "$c" -le 5 ] && \
      kb="${kb}[{\"text\":\"🔄 ${c}. ${bid}\",\"callback_data\":\"r_${bfn}\"}],"
  done

  kb="${kb}[{\"text\":\"🔙 رجوع\",\"callback_data\":\"mn\"}]]}"

  if [ "$c" -eq 0 ]; then
    sk "📋 <b>لا توجد نسخ</b>" "$MM"
  else
    sk "📋 <b>آخر ${c} نسخ:</b>
${txt}
اضغط للاسترجاع:" "$kb"
  fi
}

# ── تحميل آخر نسخة ──
do_dl() {
  la=$(ls -t "$H"/*.json 2>/dev/null | head -1)
  if [ -z "$la" ]; then
    sk "📭 لا نسخ" "$MM"; return
  fi
  bid=$(jq -r '.id // "?"' "$la" 2>/dev/null)
  sm "📥 آخر نسخة: <code>$bid</code>

الملفات بالقناة 📌
ابحث: <code>#n8n_backup ${bid}</code>"
  menu
}

# ── تنظيف ──
do_cl() {
  t=$(ls "$H"/*.json 2>/dev/null | wc -l || echo 0)
  if [ "$t" -le 5 ]; then
    sk "✅ لا حاجة ($t نسخ فقط)" "$MM"; return
  fi
  d=0
  for f in $(ls -t "$H"/*.json | tail -n +6); do
    rm -f "$f"; d=$((d+1))
  done
  sk "🗑️ <b>تم!</b> حذف $d نسخة قديمة" "$MM"
}

# ── معلومات ──
do_in() {
  sk "ℹ️ <b>معلومات</b>

🌐 <code>${N8N_HOST:-localhost}</code>
📱 Chat: <code>${TG_CHAT_ID}</code>
⏱️ فحص: <code>${MONITOR_INTERVAL:-30}s</code>
⏱️ إجباري: <code>${FORCE_BACKUP_EVERY_SEC:-900}s</code>
📦 قطعة: <code>${CHUNK_SIZE_BYTES:-19000000}</code>

<b>الأوامر:</b>
/start /status /backup /list /info" "$MM"
}

# ── استرجاع ──
do_r() {
  fn="$1"
  fl="$H/${fn}.json"
  [ -f "$fl" ] || { sm "❌ مو موجودة"; menu; return; }
  bid=$(jq -r '.id // "?"' "$fl" 2>/dev/null)
  ck='{"inline_keyboard":[[{"text":"✅ أكيد!","callback_data":"cr_'"$fn"'"}],[{"text":"❌ إلغاء","callback_data":"mn"}]]}'
  sk "⚠️ <b>استرجاع؟</b>

🆔 <code>$bid</code>

⚠️ يستبدل البيانات الحالية!" "$ck"
}

do_cr() {
  fn="$1"
  fl="$H/${fn}.json"
  [ -f "$fl" ] || { sm "❌ مو موجودة"; menu; return; }
  sm "⏳ <b>جاري الاسترجاع...</b>"

  bid=$(jq -r '.id // "?"' "$fl" 2>/dev/null)
  tmp="/tmp/rb$$"
  rm -rf "$tmp"; mkdir -p "$tmp"

  # تحميل الملفات
  fail=""
  jq -r '.files[] | "\(.f)|\(.n)"' "$fl" 2>/dev/null | \
  while IFS='|' read -r fid fname; do
    [ -n "$fid" ] || continue
    p=$(curl -sS "${TG}/getFile?file_id=$fid" | jq -r '.result.file_path // empty' 2>/dev/null)
    [ -n "$p" ] && curl -sS -o "$tmp/$fname" \
      "https://api.telegram.org/file/bot${TG_BOT_TOKEN}/${p}" || echo "F" > "$tmp/.f"
    sleep 1
  done

  if [ -f "$tmp/.f" ]; then
    sk "❌ <b>فشل التحميل</b>" "$MM"
    rm -rf "$tmp"; return
  fi

  # حذف القديم
  sqlite3 "$D/database.sqlite" "PRAGMA wal_checkpoint(TRUNCATE);" 2>/dev/null || true
  rm -f "$D/database.sqlite" "$D/database.sqlite-wal" "$D/database.sqlite-shm"

  # استرجاع
  if ls "$tmp"/d.gz.p* >/dev/null 2>&1; then
    cat "$tmp"/d.gz.p* | gzip -dc | sqlite3 "$D/database.sqlite"
  elif [ -f "$tmp/d.gz" ]; then
    gzip -dc "$tmp/d.gz" | sqlite3 "$D/database.sqlite"
  fi

  if ls "$tmp"/f.gz.p* >/dev/null 2>&1; then
    cat "$tmp"/f.gz.p* | gzip -dc | tar -C "$D" -xf - 2>/dev/null || true
  elif [ -f "$tmp/f.gz" ]; then
    gzip -dc "$tmp/f.gz" | tar -C "$D" -xf - 2>/dev/null || true
  fi

  rm -rf "$tmp"

  if [ -s "$D/database.sqlite" ]; then
    tc=$(sqlite3 "$D/database.sqlite" "SELECT count(*) FROM sqlite_master WHERE type='table';" 2>/dev/null || echo 0)
    sk "✅ <b>تم الاسترجاع!</b>

🆔 <code>$bid</code>
📋 جداول: <code>$tc</code>

⚠️ أعد تشغيل الخدمة من Render" "$MM"
  else
    sk "❌ <b>فشل</b>" "$MM"
  fi
}

# ══════════════════════════════
# حلقة الاستماع
# ══════════════════════════════
echo "🤖 جاهز..."

while true; do
  U=$(curl -sS "${TG}/getUpdates?offset=${OFF}&timeout=30" 2>/dev/null || true)
  [ -n "$U" ] || { sleep 5; continue; }
  [ "$(echo "$U" | jq -r '.ok // "false"')" = "true" ] || { sleep 5; continue; }

  echo "$U" | jq -c '.result[]' 2>/dev/null | while read -r u; do
    uid=$(echo "$u" | jq -r '.update_id')
    OFF=$((uid+1))

    # رسالة
    tx=$(echo "$u" | jq -r '.message.text // empty' 2>/dev/null)
    fr=$(echo "$u" | jq -r '.message.from.id // 0' 2>/dev/null)

    if [ -n "$tx" ] && [ "$fr" = "$TG_ADMIN_ID" ]; then
      case "$tx" in
        /start|/menu) menu ;;
        /status) do_st ;;
        /backup|/save) do_bk ;;
        /list) do_ls ;;
        /info|/help) do_in ;;
      esac
    fi

    # أزرار
    ci=$(echo "$u" | jq -r '.callback_query.id // empty' 2>/dev/null)
    cd=$(echo "$u" | jq -r '.callback_query.data // empty' 2>/dev/null)
    cf=$(echo "$u" | jq -r '.callback_query.from.id // 0' 2>/dev/null)

    if [ -n "$ci" ] && [ "$cf" = "$TG_ADMIN_ID" ]; then
      ac "$ci"
      case "$cd" in
        mn) menu ;;
        st) do_st ;;
        bk) do_bk ;;
        ls) do_ls ;;
        dl) do_dl ;;
        cl) do_cl ;;
        in) do_in ;;
        r_*) do_r "$(echo "$cd" | sed 's/^r_//')" ;;
        cr_*) do_cr "$(echo "$cd" | sed 's/^cr_//')" ;;
      esac
    fi
  done

  la=$(echo "$U" | jq -r '.result[-1].update_id // empty' 2>/dev/null)
  [ -n "$la" ] && OFF=$((la+1))
done
