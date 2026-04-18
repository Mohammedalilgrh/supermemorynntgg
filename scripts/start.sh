#!/bin/sh
set -eu
umask 077

N8N_DIR="${N8N_DIR:-/home/node/.n8n}"
WORK="${WORK:-/backup-data}"
MONITOR_INTERVAL="${MONITOR_INTERVAL:-300}"
N8N_PORT="${PORT:-${N8N_PORT:-5678}}"
export N8N_PORT
export HOME="/home/node"

mkdir -p \
  "$N8N_DIR" \
  "$N8N_DIR/nodes" \
  "$N8N_DIR/binaryData" \
  "$WORK" \
  /tmp/ffmpeg-temp \
  /tmp/ffmpeg-cache \
  /var/log/ffmpeg

: "${TG_BOT_TOKEN:?Set TG_BOT_TOKEN}"
: "${TG_CHAT_ID:?Set TG_CHAT_ID}"
: "${TG_ADMIN_ID:?Set TG_ADMIN_ID}"

TG="https://api.telegram.org/bot${TG_BOT_TOKEN}"

tg_msg() {
  curl -sS --max-time 10 \
    -X POST "${TG}/sendMessage" \
    -d "chat_id=${TG_ADMIN_ID}" \
    -d "parse_mode=HTML" \
    -d "text=$1" \
    > /dev/null 2>&1 || true
}

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  n8n + Telegram Backup v5.2 FINAL             ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
echo "📡 Port   : $N8N_PORT"
echo "🗄️  DB     : $N8N_DIR/database.sqlite"
echo "🌍 TZ     : ${TZ:-UTC}"
echo "🎬 FFmpeg : $(ffmpeg -version 2>&1 | head -1)"
echo ""

# ══════════════════════════════════════
# Community nodes check
# ══════════════════════════════════════
echo "📦 Checking community nodes..."
mkdir -p "$N8N_DIR/nodes"
cd "$N8N_DIR/nodes"
[ ! -f "package.json" ] && \
  npm init -y > /dev/null 2>&1 || true
for pkg in "@mookielianhd/n8n-nodes-instagram"; do
  if [ ! -d "node_modules/$pkg" ]; then
    echo "  📥 Installing: $pkg"
    npm install \
      --save --no-audit --no-fund \
      "$pkg" > /dev/null 2>&1 \
    && echo "  ✅ $pkg" \
    || echo "  ⚠️  $pkg failed"
  else
    echo "  ✅ $pkg present"
  fi
done
cd "$HOME"
echo "✅ Nodes OK"

# ══════════════════════════════════════
# DB Schema fix (n8n 2.6.2)
# ══════════════════════════════════════
fix_db_schema() {
  _db="$1"
  echo "🔧 Checking DB schema..."

  _has_user=$(sqlite3 "$_db" \
    "SELECT count(*) FROM sqlite_master \
     WHERE type='table' AND name='user';" \
    2>/dev/null || echo "0")

  [ "$_has_user" = "0" ] && \
    echo "ℹ️  Fresh DB" && return 0

  _has_role=$(sqlite3 "$_db" \
    "SELECT count(*) \
     FROM pragma_table_info('user') \
     WHERE name='role';" \
    2>/dev/null || echo "0")

  if [ "$_has_role" = "0" ]; then
    echo "⚠️  Adding User.role..."
    sqlite3 "$_db" "
      BEGIN TRANSACTION;
      ALTER TABLE user
        ADD COLUMN role TEXT
        NOT NULL DEFAULT 'global:member';
      UPDATE user SET role = 'global:owner'
        WHERE id = (SELECT MIN(id) FROM user);
      UPDATE user SET role = 'global:member'
        WHERE role IS NULL;
      COMMIT;
    " 2>/dev/null \
    && echo "✅ Schema fixed" \
    || {
      echo "❌ Fix failed - fresh start"
      mv "$_db" \
        "${_db}.broken.$(date +%s)" \
        2>/dev/null || true
    }
  else
    echo "✅ Schema OK"
  fi
}

# ══════════════════════════════════════
# الاسترجاع
# ══════════════════════════════════════
if [ ! -s "$N8N_DIR/database.sqlite" ]; then
  echo "📦 جاري الاسترجاع..."
  [ -f /scripts/restore.sh ] && \
    sh /scripts/restore.sh 2>&1 || true

  if [ -s "$N8N_DIR/database.sqlite" ]; then
    _tc=$(sqlite3 "$N8N_DIR/database.sqlite" \
      "SELECT count(*) FROM sqlite_master \
       WHERE type='table';" \
      2>/dev/null || echo 0)
    echo "✅ تم الاسترجاع! ($_tc جدول)"
    fix_db_schema "$N8N_DIR/database.sqlite"
  else
    echo "🆕 أول تشغيل"
  fi
else
  echo "✅ الداتابيس موجودة"
  fix_db_schema "$N8N_DIR/database.sqlite"
fi

# ══════════════════════════════════════
# تنظيف عند التشغيل
# ══════════════════════════════════════
rm -rf "$N8N_DIR/binaryData" 2>/dev/null || true
mkdir -p "$N8N_DIR/binaryData"
echo "🧹 binaryData نظيف"

# ══════════════════════════════════════
# تنظيف سجلات الداتابيس
# ══════════════════════════════════════
if [ -s "$N8N_DIR/database.sqlite" ]; then
  echo "🗄️ تنظيف سجلات قديمة..."
  _before=$(du -h "$N8N_DIR/database.sqlite" \
    2>/dev/null | cut -f1 || echo "?")
  sqlite3 "$N8N_DIR/database.sqlite" "
    DELETE FROM execution_entity
      WHERE finished = 1;
    DELETE FROM execution_data
      WHERE executionId NOT IN
        (SELECT id FROM execution_entity);
    VACUUM;
  " 2>/dev/null || true
  _after=$(du -h "$N8N_DIR/database.sqlite" \
    2>/dev/null | cut -f1 || echo "?")
  echo "✅ DB: $_before → $_after"
fi

echo ""

# ══════════════════════════════════════
# الخلفية: بوت + باك أب
# ══════════════════════════════════════
(
  _wait=0
  while [ "$_wait" -lt 120 ]; do
    if curl -sf --max-time 3 \
        "http://localhost:${N8N_PORT}/healthz" \
        > /dev/null 2>&1; then
      break
    fi
    sleep 3
    _wait=$((_wait + 3))
  done

  tg_msg "🚀 <b>n8n شغّال!</b> أرسل /start"

  [ -f /scripts/bot.sh ] && \
    sh /scripts/bot.sh 2>&1 \
      | sed 's/^/[bot] /' & \
    echo "[bg] Bot started" || \
    echo "[bg] ⚠️  bot.sh not found"

  sleep 30
  if [ -s "$N8N_DIR/database.sqlite" ] && \
     [ -f /scripts/backup.sh ]; then
    rm -f "$WORK/.backup_state"
    sh /scripts/backup.sh 2>&1 \
      | sed 's/^/[backup] /' || true
  fi

  while true; do
    sleep "$MONITOR_INTERVAL"
    [ -s "$N8N_DIR/database.sqlite" ] && \
    [ -f /scripts/backup.sh ] && \
      sh /scripts/backup.sh 2>&1 \
        | sed 's/^/[backup] /' || true
  done
) &

# ══════════════════════════════════════
# Keep-Alive (fixes Schedule Trigger)
# Pings every 290s - beats Render 15min timeout
# ══════════════════════════════════════
(
  sleep 60
  echo "[keepalive] Started - ping every 290s"
  while true; do
    _s=$(curl -sf --max-time 10 \
      "http://localhost:${N8N_PORT}/healthz" \
      2>/dev/null \
      && echo "ok" || echo "fail")
    echo "[keepalive] $(date '+%H:%M:%S') → $_s"
    [ "$_s" = "fail" ] && \
      tg_msg \
        "⚠️ <b>n8n health check failed!</b>"
    sleep 290
  done
) &

# ══════════════════════════════════════
# تنظيف binaryData كل 10 دقائق
# ══════════════════════════════════════
(
  sleep 600
  while true; do
    if [ -d "$N8N_DIR/binaryData" ]; then
      find "$N8N_DIR/binaryData" \
        -type f -mmin +10 -delete \
        2>/dev/null || true
      find "$N8N_DIR/binaryData" \
        -type d -empty -delete \
        2>/dev/null || true
    fi
    sleep 600
  done
) &

# ══════════════════════════════════════
# تنظيف سجلات الداتابيس كل ساعة
# ══════════════════════════════════════
(
  sleep 3600
  while true; do
    if [ -s "$N8N_DIR/database.sqlite" ]; then
      sqlite3 "$N8N_DIR/database.sqlite" "
        DELETE FROM execution_entity
          WHERE finished = 1;
        DELETE FROM execution_data
          WHERE executionId NOT IN
            (SELECT id FROM execution_entity);
        VACUUM;
      " 2>/dev/null || true
      echo "[db-clean] 🗄️ تم تنظيف السجلات"
    fi
    sleep 3600
  done
) &

# ══════════════════════════════════════
# تشغيل n8n
# ══════════════════════════════════════
echo "🚀 تشغيل n8n على port $N8N_PORT..."
exec n8n start
