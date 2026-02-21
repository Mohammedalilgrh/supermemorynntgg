#!/bin/bash
set -eu
umask 077

: "${TG_BOT_TOKEN:?}"
: "${TG_CHAT_ID:?}"

N8N_DIR="${N8N_DIR:-/home/node/.n8n}"
WORK="${WORK:-/backup-data}"
HIST="$WORK/history"
TG="https://api.telegram.org/bot${TG_BOT_TOKEN}"
TMP="$WORK/_restore_tmp"

trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT
mkdir -p "$N8N_DIR" "$WORK" "$HIST"
rm -rf "$TMP" 2>/dev/null || true
mkdir -p "$TMP"

if [ -s "$N8N_DIR/database.sqlite" ]; then
  _tc=$(sqlite3 "$N8N_DIR/database.sqlite" \
    "SELECT count(*) FROM sqlite_master WHERE type='table';" 2>/dev/null || echo 0)
  if [ "$_tc" -gt 5 ]; then
    echo "✅ DB موجودة وصالحة ($_tc جدول)"
    exit 0
  fi
fi

echo "=== 🔍 البحث عن باك أب ==="

# ══════════════════════════════════════════════
# تحميل ملف
# ══════════════════════════════════════════════
dl_file() {
  _fid="$1"
  _out="$2"
  _maxtry="${3:-3}"
  _try=0
  while [ "$_try" -lt "$_maxtry" ]; do
    _resp=$(curl -sS --max-time 15 \
      "${TG}/getFile?file_id=${_fid}" 2>/dev/null || true)
    _path=$(echo "$_resp" | jq -r '.result.file_path // empty' 2>/dev/null || true)
    if [ -n "$_path" ]; then
      if curl -sS --max-time 120 -o "$_out" \
        "https://api.telegram.org/file/bot${TG_BOT_TOKEN}/${_path}" 2>/dev/null; then
        [ -s "$_out" ] && return 0
      fi
    fi
    _try=$((_try + 1))
    echo "    ⚠️ محاولة $_try/$_maxtry"
    sleep 3
  done
  return 1
}

# ══════════════════════════════════════════════
# الاسترجاع
# ══════════════════════════════════════════════
restore_from_manifest() {
  _mfile="$1"

  if ! jq empty "$_mfile" 2>/dev/null; then
    echo "❌ مانيفست تالف"
    return 1
  fi

  _bid=$(jq -r '.id // "unknown"' "$_mfile")
  _bfc=$(jq -r '.file_count // 0' "$_mfile")
  _bdb=$(jq -r '.db_size // "?"' "$_mfile")
  echo "📋 $_bid | ملفات: $_bfc | DB: $_bdb"

  # ── ملفات DB فقط ──
  _db_list=$(jq -r \
    '.files[] | select(.name | startswith("db.")) | "\(.file_id)|\(.name)"' \
    "$_mfile" 2>/dev/null | sort -t'|' -k2 || true)

  [ -n "$_db_list" ] || {
    echo "❌ لا توجد ملفات DB"
    return 1
  }

  _db_count=$(echo "$_db_list" | wc -l | tr -d ' ')
  echo "🗄️ DB: $_db_count جزء"

  rm -f "$N8N_DIR/database.sqlite" \
        "$N8N_DIR/database.sqlite-wal" \
        "$N8N_DIR/database.sqlite-shm" 2>/dev/null || true

  # ── تحميل ──
  mkdir -p "$TMP/dbp"

  while IFS='|' read -r _fid _fn; do
    [ -n "$_fid" ] && [ -n "$_fn" ] || continue
    echo "  📥 $_fn"
    if dl_file "$_fid" "$TMP/dbp/$_fn" 3; then
      echo "  ✅ $_fn ($(du -h "$TMP/dbp/$_fn" | cut -f1))"
    else
      echo "  ❌ $_fn"
      touch "$TMP/dbp/.failed"
    fi
    sleep 1
  done <<< "$_db_list"

  [ ! -f "$TMP/dbp/.failed" ] || {
    echo "❌ فشل تحميل DB"
    rm -rf "$TMP/dbp"
    return 1
  }

  _actual=$(find "$TMP/dbp" -type f -name 'db.*' | wc -l)
  [ "$_actual" -gt 0 ] || {
    echo "❌ لا ملفات DB"
    rm -rf "$TMP/dbp"
    return 1
  }

  # ── بناء DB ──
  echo "🔧 بناء DB..."

  if [ "$_actual" -eq 1 ]; then
    _f=$(find "$TMP/dbp" -type f -name 'db.*' | head -1)
    gzip -dc "$_f" 2>/dev/null | sqlite3 "$N8N_DIR/database.sqlite" 2>/dev/null
  else
    cat $(find "$TMP/dbp" -type f -name 'db.*' | sort) 2>/dev/null | \
      gzip -dc 2>/dev/null | sqlite3 "$N8N_DIR/database.sqlite" 2>/dev/null
  fi

  rm -rf "$TMP/dbp"

  [ -s "$N8N_DIR/database.sqlite" ] || {
    echo "❌ DB فارغة"
    return 1
  }

  _tc=$(sqlite3 "$N8N_DIR/database.sqlite" \
    "SELECT count(*) FROM sqlite_master WHERE type='table';" 2>/dev/null || echo 0)
  [ "$_tc" -gt 3 ] || {
    echo "❌ DB تالفة ($_tc جداول)"
    rm -f "$N8N_DIR/database.sqlite"
    return 1
  }

  _users=$(sqlite3 "$N8N_DIR/database.sqlite" \
    "SELECT count(*) FROM \"user\";" 2>/dev/null || echo 0)
  _emails=$(sqlite3 "$N8N_DIR/database.sqlite" \
    "SELECT email FROM \"user\" LIMIT 5;" 2>/dev/null || echo "none")
  _creds=$(sqlite3 "$N8N_DIR/database.sqlite" \
    "SELECT count(*) FROM credentials_entity;" 2>/dev/null || echo 0)
  _wf=$(sqlite3 "$N8N_DIR/database.sqlite" \
    "SELECT count(*) FROM workflow_entity;" 2>/dev/null || echo 0)

  echo ""
  echo "✅ DB:"
  echo "   📋 جداول: $_tc"
  echo "   👤 مستخدمين: $_users"
  echo "   📧 emails: $_emails"
  echo "   🔑 credentials: $_creds"
  echo "   ⚙️ workflows: $_wf"

  # ══════════════════════════════════════════
  # إصلاح owner setup - كل الصيغ الممكنة
  # هذا يمنع /setup من الظهور
  # ══════════════════════════════════════════
  if [ "$_users" -gt 0 ]; then
    echo ""
    echo "🔧 إصلاح إعدادات n8n..."

    # أولاً نشوف الإعدادات الحالية
    echo "  الإعدادات قبل الإصلاح:"
    sqlite3 "$N8N_DIR/database.sqlite" \
      "SELECT key, value FROM settings WHERE key LIKE '%owner%' OR key LIKE '%userManagement%';" \
      2>/dev/null || true

    # إصلاح بكل الصيغ الممكنة
    sqlite3 "$N8N_DIR/database.sqlite" <<'FIXSQL'
-- حذف القديمة
DELETE FROM settings WHERE key = 'userManagement.isInstanceOwnerSetUp';

-- إدراج بالصيغة الصحيحة (بدون علامات تنصيص حول true)
INSERT INTO settings (key, value, "loadOnStartup")
VALUES ('userManagement.isInstanceOwnerSetUp', 'true', 1);

-- تأكد أن أول مستخدم هو global:owner
UPDATE "user" SET role = 'global:owner'
WHERE id = (SELECT id FROM "user" ORDER BY "createdAt" ASC LIMIT 1)
AND role IS NOT NULL;

-- تأكد من وجود personal project لكل مستخدم
INSERT OR IGNORE INTO project (id, name, type)
SELECT
  lower(hex(randomblob(8)) || '-' || hex(randomblob(4)) || '-4' || substr(hex(randomblob(2)),2) || '-' || substr('89ab',abs(random()) % 4 + 1, 1) || substr(hex(randomblob(2)),2) || '-' || hex(randomblob(6))),
  email,
  'personal'
FROM "user"
WHERE id NOT IN (
  SELECT pr."userId" FROM project_relation pr
  JOIN project p ON p.id = pr."projectId"
  WHERE p.type = 'personal'
);
FIXSQL

    echo "  الإعدادات بعد الإصلاح:"
    sqlite3 "$N8N_DIR/database.sqlite" \
      "SELECT key, value FROM settings WHERE key LIKE '%owner%' OR key LIKE '%userManagement%';" \
      2>/dev/null || true

    # تحقق من role أول مستخدم
    _first_role=$(sqlite3 "$N8N_DIR/database.sqlite" \
      "SELECT role FROM \"user\" ORDER BY \"createdAt\" ASC LIMIT 1;" \
      2>/dev/null || echo "?")
    echo "  أول مستخدم role: $_first_role"
  fi

  # ══════════════════════════════════════════
  # إعدادات الملفات (فقط إذا قليلة)
  # ══════════════════════════════════════════
  _cfg_count=$(jq -r '.files[] | select(.name | startswith("files.")) | .name' \
    "$_mfile" 2>/dev/null | wc -l || echo 0)

  if [ "$_cfg_count" -gt 0 ] && [ "$_cfg_count" -le 3 ]; then
    echo "📁 إعدادات ($_cfg_count)..."
    mkdir -p "$TMP/cfgp"

    jq -r '.files[] | select(.name | startswith("files.")) | "\(.file_id)|\(.name)"' \
      "$_mfile" 2>/dev/null | sort -t'|' -k2 | \
    while IFS='|' read -r _fid _fn; do
      [ -n "$_fid" ] && [ -n "$_fn" ] || continue
      dl_file "$_fid" "$TMP/cfgp/$_fn" 3 || true
      sleep 1
    done

    if find "$TMP/cfgp" -type f -name 'files.*' | grep -q '.'; then
      cat $(find "$TMP/cfgp" -type f -name 'files.*' | sort) | gzip -dc | \
        tar -C "$N8N_DIR" -xf - \
          --exclude='./binaryData' \
          --exclude='./binaryData/*' \
          --exclude='./.cache' \
          --exclude='./database.sqlite' \
          --exclude='./database.sqlite-wal' \
          --exclude='./database.sqlite-shm' \
          2>/dev/null || true
      echo "  ✅ إعدادات"
    fi
    rm -rf "$TMP/cfgp"
  elif [ "$_cfg_count" -gt 3 ]; then
    echo "⏭️ تخطي إعدادات (binaryData: $_cfg_count جزء)"
  fi

  # ══════════════════════════════════════════
  # config + encryption key
  # ══════════════════════════════════════════
  if [ -n "${N8N_ENCRYPTION_KEY:-}" ]; then
    echo "🔐 كتابة config..."
    printf '{"encryptionKey":"%s"}' "$N8N_ENCRYPTION_KEY" > "$N8N_DIR/config"
    echo "  ✅ config"
  fi

  cp "$_mfile" "$HIST/${_bid}.json" 2>/dev/null || true

  rm -rf "$TMP"
  echo ""
  echo "🎉 اكتمل: $_bid | $_tc جدول | $_users مستخدم | $_wf workflow"
  return 0
}

# ════════════════════════════════════════════
# طريقة 1: مثبّتة
# ════════════════════════════════════════════
echo ""
echo "🔍 [1/3] المثبّتة..."

_chat=$(curl -sS --max-time 15 \
  "${TG}/getChat?chat_id=${TG_CHAT_ID}" 2>/dev/null || true)
_pin_fid=$(echo "$_chat" | jq -r '.result.pinned_message.document.file_id // empty' 2>/dev/null || true)
_pin_cap=$(echo "$_chat" | jq -r '.result.pinned_message.caption // ""' 2>/dev/null || true)

if [ -n "$_pin_fid" ] && echo "$_pin_cap" | grep -q "n8n_manifest"; then
  echo "  📌 مانيفست!"
  if dl_file "$_pin_fid" "$TMP/m1.json" 3; then
    restore_from_manifest "$TMP/m1.json" && exit 0
    echo "  ⚠️ فشل"
  fi
else
  echo "  📭 لا"
fi

# ════════════════════════════════════════════
# طريقة 2: رسائل
# ════════════════════════════════════════════
echo ""
echo "🔍 [2/3] رسائل..."

_upd=$(curl -sS --max-time 20 \
  "${TG}/getUpdates?offset=-100&limit=100" 2>/dev/null || true)
_fid2=""
[ -n "$_upd" ] && _fid2=$(echo "$_upd" | jq -r '
  [.result[] |
   select((.channel_post.document != null) and
          ((.channel_post.caption // "") | test("n8n_manifest")))] |
  sort_by(-.channel_post.date) |
  .[0].channel_post.document.file_id // empty
' 2>/dev/null || true)

if [ -n "$_fid2" ]; then
  echo "  📋 مانيفست!"
  dl_file "$_fid2" "$TMP/m2.json" 3 && \
    restore_from_manifest "$TMP/m2.json" && exit 0
fi
echo "  📭 لا"

# ════════════════════════════════════════════
# طريقة 3: محلي
# ════════════════════════════════════════════
echo ""
echo "🔍 [3/3] محلي..."

_local=$(ls -t "$HIST"/*.json 2>/dev/null | head -1 || true)
if [ -n "$_local" ] && [ -f "$_local" ]; then
  echo "  📂 $(basename "$_local")"
  restore_from_manifest "$_local" && exit 0
fi
echo "  📭 لا"

echo ""
echo "📭 لا توجد نسخة"
exit 0
