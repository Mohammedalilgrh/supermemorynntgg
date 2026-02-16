#!/bin/sh
set -eu
umask 077

: "${TG_BOT_TOKEN:?}" "${TG_CHAT_ID:?}"

D="${N8N_DIR:-/home/node/.n8n}"
W="${WORK:-/backup-data}"
H="$W/h"

MI="${MIN_BACKUP_INTERVAL_SEC:-30}"
FI="${FORCE_BACKUP_EVERY_SEC:-900}"
BB="${BACKUP_BINARYDATA:-true}"
# 19MB - أقل من حد Telegram 20MB للتحميل
CS="${CHUNK_SIZE_BYTES:-19000000}"

S="$W/.bs"
L="$W/.bl"
TMP="$W/_bt"
TG="https://api.telegram.org/bot${TG_BOT_TOKEN}"

mkdir -p "$W" "$H"

# قفل
mkdir "$L" 2>/dev/null || exit 0
trap 'rmdir "$L" 2>/dev/null; rm -rf "$TMP" 2>/dev/null' EXIT

# ── كشف التغيير ──
dsig() {
  s=""
  for f in database.sqlite database.sqlite-wal database.sqlite-shm; do
    [ -f "$D/$f" ] && s="${s}$(stat -c '%Y%s' "$D/$f" 2>/dev/null);" || true
  done
  printf "%s" "$s"
}

bsig() {
  [ "$BB" = "true" ] || { printf "s"; return; }
  [ -d "$D/binaryData" ] || { printf "n"; return; }
  du -sk "$D/binaryData" 2>/dev/null | awk '{print $1}'
}

chk() {
  [ -f "$D/database.sqlite" ] || { echo "X"; return; }
  n=$(date +%s); le=0; lf=0; ld=""; lb=""
  if [ -f "$S" ]; then
    le=$(grep '^E=' "$S" 2>/dev/null | cut -d= -f2 || echo 0)
    lf=$(grep '^F=' "$S" 2>/dev/null | cut -d= -f2 || echo 0)
    ld=$(grep '^D=' "$S" 2>/dev/null | cut -d= -f2- || true)
    lb=$(grep '^B=' "$S" 2>/dev/null | cut -d= -f2- || true)
  fi
  cd=$(dsig); cb=$(bsig)
  [ $((n-lf)) -ge "$FI" ] && { echo "FORCE"; return; }
  [ "$cd" = "$ld" ] && [ "$cb" = "$lb" ] && { echo "SAME"; return; }
  [ $((n-le)) -lt "$MI" ] && { echo "WAIT"; return; }
  echo "GO"
}

R=$(chk)
case "$R" in X|SAME|WAIT) exit 0;; esac

ID=$(date +"%Y%m%d_%H%M%S")
TS=$(date -u +"%Y-%m-%dT%H:%M:%SZ")

echo "📦 $ID ($R)"

rm -rf "$TMP"; mkdir -p "$TMP/p"

# ── DB dump ──
sqlite3 "$D/database.sqlite" ".timeout 10000" \
  "PRAGMA wal_checkpoint(TRUNCATE);" >/dev/null 2>&1 || true

sqlite3 "$D/database.sqlite" ".timeout 10000" ".dump" 2>/dev/null \
  | gzip -n -1 -c > "$TMP/d.gz"

[ -s "$TMP/d.gz" ] || { echo "❌ DB"; exit 1; }
DBS=$(du -h "$TMP/d.gz" | cut -f1)

# ── ملفات إضافية ──
exc="--exclude=database.sqlite --exclude=database.sqlite-wal --exclude=database.sqlite-shm"
[ "$BB" != "true" ] && exc="$exc --exclude=binaryData"
tar -C "$D" -cf - $exc . 2>/dev/null | gzip -n -1 -c > "$TMP/f.gz" || true
FS="0"
[ -s "$TMP/f.gz" ] && FS=$(du -h "$TMP/f.gz" | cut -f1)

# ── تقسيم (كل جزء < 19MB حتى Telegram يكدر يحمّله) ──
for src in d.gz f.gz; do
  [ -s "$TMP/$src" ] || continue
  sz=$(stat -c '%s' "$TMP/$src" 2>/dev/null || echo 0)
  if [ "$sz" -gt "$CS" ]; then
    split -b "$CS" -d -a 3 "$TMP/$src" "$TMP/p/${src}.p"
    rm -f "$TMP/$src"
  else
    mv "$TMP/$src" "$TMP/p/$src"
  fi
done

# ── رفع ──
MF=""
FC=0
OK=true

for f in "$TMP/p"/*; do
  [ -f "$f" ] || continue
  fn=$(basename "$f")
  try=0; res=""
  while [ "$try" -lt 3 ]; do
    rsp=$(curl -sS -X POST "${TG}/sendDocument" \
      -F "chat_id=${TG_CHAT_ID}" \
      -F "document=@${f}" \
      -F "caption=🗂 #n8n_backup ${ID} | ${fn}" 2>/dev/null || true)

    fid=$(echo "$rsp" | jq -r '.result.document.file_id // empty' 2>/dev/null || true)
    mid=$(echo "$rsp" | jq -r '.result.message_id // empty' 2>/dev/null || true)
    ok=$(echo "$rsp" | jq -r '.ok // "false"' 2>/dev/null || true)

    if [ "$ok" = "true" ] && [ -n "$fid" ]; then
      res="y"
      MF="${MF}{\"m\":${mid},\"f\":\"${fid}\",\"n\":\"${fn}\"},"
      FC=$((FC+1))
      break
    fi
    try=$((try+1)); sleep 3
  done
  [ -n "$res" ] || { OK=false; break; }
  sleep 1
done

[ "$OK" = "true" ] || { echo "❌ رفع"; exit 1; }

MF=$(echo "$MF" | sed 's/,$//')

# ── مانيفست ──
cat > "$TMP/m.json" <<EOF
{"id":"$ID","ts":"$TS","v":"4","db":"$DBS","fs":"$FS","fc":$FC,"bb":"$BB","files":[$MF]}
EOF

cp "$TMP/m.json" "$H/${ID}.json"

mr=$(curl -sS -X POST "${TG}/sendDocument" \
  -F "chat_id=${TG_CHAT_ID}" \
  -F "document=@$TMP/m.json;filename=m_${ID}.json" \
  -F "caption=📋 #n8n_manifest
🆔 ${ID} | 🕒 ${TS}
📦 ${FC} | 📊 ${DBS}" 2>/dev/null || true)

mm=$(echo "$mr" | jq -r '.result.message_id // empty' 2>/dev/null || true)
[ -n "$mm" ] && curl -sS -X POST "${TG}/pinChatMessage" \
  -d "chat_id=${TG_CHAT_ID}" -d "message_id=${mm}" \
  -d "disable_notification=true" >/dev/null 2>&1 || true

# ── حالة ──
n=$(date +%s)
cat > "$S" <<EOF
I=$ID
T=$TS
E=$n
F=$n
D=$(dsig)
B=$(bsig)
EOF

# تنظيف (آخر 15 محلياً)
lc=$(ls "$H"/*.json 2>/dev/null | wc -l || echo 0)
[ "$lc" -gt 15 ] && ls -t "$H"/*.json | tail -n +16 | xargs rm -f 2>/dev/null || true

rm -rf "$TMP"
echo "✅ $ID | $FC files | DB:$DBS"
exit 0
