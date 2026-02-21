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

# إذا DB موجودة وصالحة لا نعمل شيء
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
# دالة تحميل ملف
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
# الاسترجاع من مانيفست
# ══════════════════════════════════════════════
restore_from_manifest() {
  _mfile="$1"

  # تحقق JSON
  if ! jq empty "$_mfile" 2>/dev/null; then
    echo "❌ مانيفست تالف"
    return 1
  fi

  _bid=$(jq -r '.id // "unknown"' "$_mfile")
  _bfc=$(jq -r '.file_count // 0' "$_mfile")
  _bdb=$(jq -r '.db_size // "?"' "$_mfile")
  _ver=$(jq -r '.version // "?"' "$_mfile")
  echo "📋 باك أب: $_bid | v$_ver | ملفات: $_bfc | DB: $_bdb"

  # ── استخراج ملفات DB فقط ──
  _db_ids=""
  _db_names=""
  _db_count=0

  while IFS='|' read -r _fid _fn; do
    [ -n "$_fid" ] && [ -n "$_fn" ] || continue
    _db_ids="${_db_ids}${_fid}|${_fn}
"
    _db_count=$((_db_count + 1))
  done <<< "$(jq -r '.files[] | select(.name | startswith("db.")) | "\(.file_id)|\(.name)"' "$_mfile" 2>/dev/null)"

  if [ "$_db_count" -eq 0 ]; then
    echo "❌ لا توجد ملفات DB في المانيفست"
    return 1
  fi

  echo "🗄️ تحميل DB ($_db_count جزء)..."

  # ── تنظيف القديم ──
  rm -f "$N8N_DIR/database.sqlite" \
        "$N8N_DIR/database.sqlite-wal" \
        "$N8N_DIR/database.sqlite-shm" 2>/dev/null || true

  # ── تحميل أجزاء DB ──
  mkdir -p "$TMP/dbp"
  _dl_fail=false

  echo "$_db_ids" | sort -t'|' -k2 | while IFS='|' read -r _fid _fn; do
    [ -n "$_fid" ] && [ -n "$_fn" ] || continue
    echo "  📥 $_fn"
    if dl_file "$_fid" "$TMP/dbp/$_fn" 3; then
      _sz=$(du -h "$TMP/dbp/$_fn" | cut -f1)
      echo "  ✅ $_fn ($_sz)"
    else
      echo "  ❌ فشل: $_fn"
      touch "$TMP/dbp/.failed"
    fi
    sleep 1
  done

  if [ -f "$TMP/dbp/.failed" ]; then
    echo "❌ فشل تحميل بعض أجزاء DB"
    rm -rf "$TMP/dbp"
    return 1
  fi

  # ── تحقق من وجود الملفات ──
  _actual_files=$(find "$TMP/dbp" -type f -name 'db.*' | wc -l)
  if [ "$_actual_files" -eq 0 ]; then
    echo "❌ لم يتم تحميل أي ملفات DB"
    rm -rf "$TMP/dbp"
    return 1
  fi
  echo "📦 $_actual_files ملف(ات) DB محمّلة"

  # ── بناء DB ──
  echo "🔧 بناء قاعدة البيانات..."

  _build_ok=false
  if [ "$_actual_files" -eq 1 ]; then
    _only_file=$(find "$TMP/dbp" -type f -name 'db.*' | head -1)
    if gzip -dc "$_only_file" 2>/dev/null | sqlite3 "$N8N_DIR/database.sqlite" 2>/dev/null; then
      _build_ok=true
    fi
  else
    _sorted_files=$(find "$TMP/dbp" -type f -name 'db.*' | sort)
    if cat $_sorted_files 2>/dev/null | gzip -dc 2>/dev/null | sqlite3 "$N8N_DIR/database.sqlite" 2>/dev/null; then
      _build_ok=true
    fi
  fi

  rm -rf "$TMP/dbp"

  if [ "$_build_ok" = "false" ] || [ ! -s "$N8N_DIR/database.sqlite" ]; then
    echo "❌ فشل بناء DB"
    rm -f "$N8N_DIR/database.sqlite" 2>/dev/null || true
    return 1
  fi

  # ── تحقق من صحة DB ──
  _tc=$(sqlite3 "$N8N_DIR/database.sqlite" \
    "SELECT count(*) FROM sqlite_master WHERE type='table';" 2>/dev/null || echo 0)

  if [ "$_tc" -lt 3 ]; then
    echo "❌ DB تالفة أو فارغة ($_tc جداول)"
    rm -f "$N8N_DIR/database.sqlite" 2>/dev/null || true
    return 1
  fi

  # ── تحقق من المحتوى ──
  _users=$(sqlite3 "$N8N_DIR/database.sqlite" \
    "SELECT count(*) FROM \"user\";" 2>/dev/null || echo 0)
  _emails=$(sqlite3 "$N8N_DIR/database.sqlite" \
    "SELECT email FROM \"user\" LIMIT 5;" 2>/dev/null || echo "none")
  _creds=$(sqlite3 "$N8N_DIR/database.sqlite" \
    "SELECT count(*) FROM credentials_entity;" 2>/dev/null || echo 0)
  _wf=$(sqlite3 "$N8N_DIR/database.sqlite" \
    "SELECT count(*) FROM workflow_entity;" 2>/dev/null || echo 0)

  echo ""
  echo "✅ DB جاهزة!"
  echo "   📋 جداول: $_tc"
  echo "   👤 مستخدمين: $_users"
  echo "   📧 emails: $_emails"
  echo "   🔑 credentials: $_creds"
  echo "   ⚙️ workflows: $_wf"

  # ══════════════════════════════════════════
  # إصلاح إعداد الـ owner setup
  # هذا يمنع ظهور صفحة التسجيل
  # ══════════════════════════════════════════
  if [ "$_users" -gt 0 ]; then
    echo "🔧 إصلاح إعداد owner setup..."

    sqlite3 "$N8N_DIR/database.sqlite" <<'FIXSQL'
INSERT OR REPLACE INTO settings (key, value, "loadOnStartup")
VALUES ('userManagement.isInstanceOwnerSetUp', '"true"', 1);
FIXSQL

    _check=$(sqlite3 "$N8N_DIR/database.sqlite" \
      "SELECT value FROM settings WHERE key='userManagement.isInstanceOwnerSetUp';" 2>/dev/null || echo "?")
    echo "   ✅ ownerSetUp = $_check"
  fi

  # ══════════════════════════════════════════
  # استرجاع ملفات الإعدادات (فقط إذا قليلة)
  # ══════════════════════════════════════════
  _cfg_count=0
  while IFS='|' read -r _fid _fn; do
    [ -n "$_fid" ] && [ -n "$_fn" ] || continue
    _cfg_count=$((_cfg_count + 1))
  done <<< "$(jq -r '.files[] | select(.name | startswith("files.")) | "\(.file_id)|\(.name)"' "$_mfile" 2>/dev/null)"

  if [ "$_cfg_count" -gt 0 ] && [ "$_cfg_count" -le 3 ]; then
    echo "📁 استرجاع إعدادات ($_cfg_count ملف)..."
    mkdir -p "$TMP/cfgp"

    jq -r '.files[] | select(.name | startswith("files.")) | "\(.file_id)|\(.name)"' "$_mfile" 2>/dev/null | \
    sort -t'|' -k2 | while IFS='|' read -r _fid _fn; do
      [ -n "$_fid" ] && [ -n "$_fn" ] || continue
      echo "  📥 $_fn"
      dl_file "$_fid" "$TMP/cfgp/$_fn" 3 || true
      sleep 1
    done

    _cfg_actual=$(find "$TMP/cfgp" -type f -name 'files.*' 2>/dev/null | wc -l)
    if [ "$_cfg_actual" -gt 0 ]; then
      _cfg_sorted=$(find "$TMP/cfgp" -type f -name 'files.*' | sort)
      cat $_cfg_sorted 2>/dev/null | gzip -dc 2>/dev/null | \
        tar -C "$N8N_DIR" -xf - \
          --exclude='./binaryData' \
          --exclude='./binaryData/*' \
          --exclude='./.cache' \
          --exclude='./database.sqlite' \
          --exclude='./database.sqlite-wal' \
          --exclude='./database.sqlite-shm' \
          2>/dev/null || true
      echo "  ✅ إعدادات مسترجعة"
    fi
    rm -rf "$TMP/cfgp"

  elif [ "$_cfg_count" -gt 3 ]; then
    echo "⏭️ تخطي الإعدادات (كبيرة: $_cfg_count جزء = binaryData)"
    echo "   binaryData في Cloudflare R2 - لا حاجة"
  fi

  # ══════════════════════════════════════════
  # إنشاء/تحديث config لو مش موجود
  # ══════════════════════════════════════════
  if [ -n "${N8N_ENCRYPTION_KEY:-}" ] && [ ! -f "$N8N_DIR/config" ]; then
    echo "🔐 إنشاء config بـ encryption key..."
    printf '{"encryptionKey":"%s"}' "$N8N_ENCRYPTION_KEY" > "$N8N_DIR/config"
    echo "  ✅ config تم إنشاؤه"
  fi

  # حفظ المانيفست محلياً
  cp "$_mfile" "$HIST/${_bid}.json" 2>/dev/null || true

  rm -rf "$TMP"
  echo ""
  echo "🎉 اكتمل الاسترجاع!"
  echo "   🆔 $_bid"
  echo "   📋 $_tc جدول | 👤 $_users مستخدم | ⚙️ $_wf workflow"
  return 0
}

# ════════════════════════════════════════════
# طريقة 1: الرسالة المثبّتة
# ════════════════════════════════════════════
echo ""
echo "🔍 [1/3] الرسالة المثبّتة..."

_chat=$(curl -sS --max-time 15 \
  "${TG}/getChat?chat_id=${TG_CHAT_ID}" 2>/dev/null || true)

_pin_fid=$(echo "$_chat" | \
  jq -r '.result.pinned_message.document.file_id // empty' 2>/dev/null || true)
_pin_cap=$(echo "$_chat" | \
  jq -r '.result.pinned_message.caption // ""' 2>/dev/null || true)

if [ -n "$_pin_fid" ] && echo "$_pin_cap" | grep -q "n8n_manifest"; then
  echo "  📌 مانيفست مثبّت!"
  if dl_file "$_pin_fid" "$TMP/manifest.json" 3; then
    if restore_from_manifest "$TMP/manifest.json"; then
      exit 0
    fi
    echo "  ⚠️ فشل من المثبّت"
  fi
else
  echo "  📭 لا يوجد"
fi

# ════════════════════════════════════════════
# طريقة 2: رسائل القناة
# ════════════════════════════════════════════
echo ""
echo "🔍 [2/3] رسائل القناة..."

_upd=$(curl -sS --max-time 20 \
  "${TG}/getUpdates?offset=-100&limit=100" 2>/dev/null || true)

_fid2=""
if [ -n "$_upd" ]; then
  _fid2=$(echo "$_upd" | jq -r '
    [.result[] |
     select(
       (.channel_post.document != null) and
       ((.channel_post.caption // "") | test("n8n_manifest"))
     )] |
    sort_by(-.channel_post.date) |
    .[0].channel_post.document.file_id // empty
  ' 2>/dev/null || true)
fi

if [ -n "$_fid2" ]; then
  echo "  📋 وجدنا مانيفست!"
  if dl_file "$_fid2" "$TMP/manifest2.json" 3; then
    if restore_from_manifest "$TMP/manifest2.json"; then
      exit 0
    fi
  fi
else
  echo "  📭 لا يوجد"
fi

# ════════════════════════════════════════════
# طريقة 3: السجل المحلي
# ════════════════════════════════════════════
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
