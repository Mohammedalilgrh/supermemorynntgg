#!/bin/sh
set -eu
umask 077

# ══════════════════════════════════════════════
# Config
# ══════════════════════════════════════════════
N8N_DIR="${N8N_DIR:-/home/node/.n8n}"
WORK="${WORK:-/backup-data}"
MONITOR_INTERVAL="${MONITOR_INTERVAL:-300}"
N8N_PORT="${PORT:-${N8N_PORT:-5678}}"
export N8N_PORT
export HOME="/home/node"

# ══════════════════════════════════════════════
# Ensure directories
# ══════════════════════════════════════════════
mkdir -p \
  "$N8N_DIR" \
  "$N8N_DIR/nodes" \
  "$N8N_DIR/binaryData" \
  "$WORK" \
  /tmp/ffmpeg-temp \
  /tmp/ffmpeg-cache \
  /var/log/ffmpeg

# ══════════════════════════════════════════════
# Required env vars
# ══════════════════════════════════════════════
: "${TG_BOT_TOKEN:?TG_BOT_TOKEN is required}"
: "${TG_CHAT_ID:?TG_CHAT_ID is required}"
: "${TG_ADMIN_ID:?TG_ADMIN_ID is required}"

TG="https://api.telegram.org/bot${TG_BOT_TOKEN}"

tg_msg() {
  curl -sS --max-time 10 -X POST "${TG}/sendMessage" \
    -d "chat_id=${TG_ADMIN_ID}" \
    -d "parse_mode=HTML" \
    -d "text=$1" \
    > /dev/null 2>&1 || true
}

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║   n8n 2.6.2 + Telegram Backup - Starting      ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
echo "📡 Port    : $N8N_PORT"
echo "🗄️  DB      : $N8N_DIR/database.sqlite"
echo "🌍 TZ      : ${TZ:-UTC}"
echo "🎬 FFmpeg  : $(/usr/local/bin/ffmpeg -version \
  2>&1 | head -1)"
echo ""

# ══════════════════════════════════════════════
# Community nodes check
# ══════════════════════════════════════════════
ensure_community_nodes() {
  echo "📦 Checking community nodes..."
  mkdir -p "$N8N_DIR/nodes"
  cd "$N8N_DIR/nodes"

  [ ! -f "package.json" ] && \
    npm init -y > /dev/null 2>&1 || true

  for pkg in \
    "@mookielianhd/n8n-nodes-instagram"; \
  do
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
}

ensure_community_nodes

# ══════════════════════════════════════════════
# DB schema fix (n8n 2.6.2)
# ══════════════════════════════════════════════
fix_db_schema() {
  local db="$1"
  echo "🔧 Checking schema..."

  local has_user
  has_user=$(sqlite3 "$db" \
    "SELECT count(*) FROM sqlite_master \
     WHERE type='table' AND name='user';" \
    2>/dev/null || echo "0")

  [ "$has_user" = "0" ] && \
    echo "ℹ️  Fresh DB" && return 0

  local has_role
  has_role=$(sqlite3 "$db" \
    "SELECT count(*) FROM pragma_table_info('user') \
     WHERE name='role';" \
    2>/dev/null || echo "0")

  if [ "$has_role" = "0" ]; then
    echo "⚠️  Adding User.role..."
    sqlite3 "$db" "
      BEGIN TRANSACTION;
      ALTER TABLE user
        ADD COLUMN role TEXT
        NOT NULL DEFAULT 'global:member';
      UPDATE user SET role = 'global:owner'
        WHERE id = (SELECT MIN(id) FROM user);
      UPDATE user
        SET role = 'global:member'
        WHERE role IS NULL;
      COMMIT;
    " 2>/dev/null \
    && echo "✅ Schema fixed" \
    || {
      echo "❌ Fix failed - fresh start"
      mv "$db" "${db}.broken.$(date +%s)" \
        2>/dev/null || true
    }
  else
    echo "✅ Schema OK"
  fi
}

# ══════════════════════════════════════════════
# Restore
# ══════════════════════════════════════════════
if [ ! -s "$N8N_DIR/database.sqlite" ]; then
  echo "📦 No DB - attempting restore..."
  [ -f /scripts/restore.sh ] && \
    sh /scripts/restore.sh 2>&1 || true

  if [ -s "$N8N_DIR/database.sqlite" ]; then
    _tc=$(sqlite3 "$N8N_DIR/database.sqlite" \
      "SELECT count(*) FROM sqlite_master \
       WHERE type='table';" \
      2>/dev/null || echo 0)
    echo "✅ Restored! ($_tc tables)"
    fix_db_schema "$N8N_DIR/database.sqlite"
  else
    echo "🆕 Fresh start"
  fi
else
  _sz=$(du -h "$N8N_DIR/database.sqlite" \
    2>/dev/null | cut -f1 || echo "?")
  echo "✅ DB exists ($_sz)"
  fix_db_schema "$N8N_DIR/database.sqlite"
fi

# ══════════════════════════════════════════════
# Clean binaryData
# ══════════════════════════════════════════════
rm -rf "$N8N_DIR/binaryData" 2>/dev/null || true
mkdir -p "$N8N_DIR/binaryData"
echo "🧹 binaryData cleaned"

# ══════════════════════════════════════════════
# Clean executions
# ══════════════════════════════════════════════
if [ -s "$N8N_DIR/database.sqlite" ]; then
  echo "🗄️  Cleaning executions..."
  _b=$(du -h "$N8N_DIR/database.sqlite" \
    2>/dev/null | cut -f1 || echo "?")
  sqlite3 "$N8N_DIR/database.sqlite" "
    DELETE FROM execution_entity
      WHERE finished = 1;
    DELETE FROM execution_data
      WHERE executionId NOT IN
        (SELECT id FROM execution_entity);
    VACUUM;
  " 2>/dev/null || true
  _a=$(du -h "$N8N_DIR/database.sqlite" \
    2>/dev/null | cut -f1 || echo "?")
  echo "✅ DB: $_b → $_a"
fi

echo ""

# ══════════════════════════════════════════════
# Background: notify + bot + backup
# ══════════════════════════════════════════════
(
  echo "[bg] Waiting for n8n..."
  _w=0
  while [ "$_w" -lt 180 ]; do
    curl -sf --max-time 3 \
      "http://localhost:${N8N_PORT}/healthz" \
      > /dev/null 2>&1 && break
    sleep 5
    _w=$((_w + 5))
  done

  [ "$_w" -ge 180 ] \
    && tg_msg "⚠️ <b>n8n timeout!</b>" \
    || tg_msg "🚀 <b>n8n 2.6.2 running!</b>%0ASend /start"

  [ -f /scripts/bot.sh ] && \
    sh /scripts/bot.sh 2>&1 \
      | sed 's/^/[bot] /' & \
    echo "[bg] Bot started"

  sleep 30
  [ -s "$N8N_DIR/database.sqlite" ] && \
  [ -f /scripts/backup.sh ] && \
    rm -f "$WORK/.backup_state" && \
    sh /scripts/backup.sh 2>&1 \
      | sed 's/^/[backup] /' || true

  while true; do
    sleep "$MONITOR_INTERVAL"
    [ -s "$N8N_DIR/database.sqlite" ] && \
    [ -f /scripts/backup.sh ] && \
      sh /scripts/backup.sh 2>&1 \
        | sed 's/^/[backup] /' || true
  done
) &

# ══════════════════════════════════════════════
# Keep-alive (fixes Schedule Trigger on Render)
# Pings every 290s to prevent 15min sleep
# ══════════════════════════════════════════════
(
  sleep 90
  echo "[keepalive] Started - ping every 290s"
  while true; do
    _s=$(curl -sf --max-time 10 \
      "http://localhost:${N8N_PORT}/healthz" \
      2>/dev/null && echo "ok" || echo "fail")
    echo "[keepalive] $(date '+%H:%M:%S') $_s"
    [ "$_s" = "fail" ] && \
      tg_msg "⚠️ <b>Health check failed!</b>"
    sleep 290
  done
) &

# ══════════════════════════════════════════════
# Clean binaryData every 10min
# ══════════════════════════════════════════════
(
  sleep 600
  while true; do
    [ -d "$N8N_DIR/binaryData" ] && \
      find "$N8N_DIR/binaryData" \
        -type f -mmin +10 -delete \
        2>/dev/null || true && \
      find "$N8N_DIR/binaryData" \
        -type d -empty -delete \
        2>/dev/null || true
    sleep 600
  done
) &

# ══════════════════════════════════════════════
# Clean DB records hourly
# ══════════════════════════════════════════════
(
  sleep 3600
  while true; do
    [ -s "$N8N_DIR/database.sqlite" ] && \
      sqlite3 "$N8N_DIR/database.sqlite" "
        DELETE FROM execution_entity
          WHERE finished = 1;
        DELETE FROM execution_data
          WHERE executionId NOT IN
            (SELECT id FROM execution_entity);
        VACUUM;
      " 2>/dev/null || true && \
      echo "[db-clean] ✅ done"
    sleep 3600
  done
) &

# ══════════════════════════════════════════════
# Start n8n
# ══════════════════════════════════════════════
echo "🚀 Starting n8n 2.6.2 on port $N8N_PORT..."
exec n8n start
