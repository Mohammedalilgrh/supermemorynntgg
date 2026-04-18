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
# Ensure directories exist (Render ephemeral fs)
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
# Validate required env vars
# ══════════════════════════════════════════════
: "${TG_BOT_TOKEN:?TG_BOT_TOKEN is required}"
: "${TG_CHAT_ID:?TG_CHAT_ID is required}"
: "${TG_ADMIN_ID:?TG_ADMIN_ID is required}"

TG="https://api.telegram.org/bot${TG_BOT_TOKEN}"

# ══════════════════════════════════════════════
# Telegram helper
# ══════════════════════════════════════════════
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
echo "📡 Port      : $N8N_PORT"
echo "🗄️  DB        : $N8N_DIR/database.sqlite"
echo "🌍 Timezone  : ${TZ:-UTC}"
echo "🎬 FFmpeg    : $(/usr/local/bin/ffmpeg -version 2>&1 | head -1)"
echo ""

# ══════════════════════════════════════════════
# Community nodes check + reinstall if missing
# ══════════════════════════════════════════════
ensure_community_nodes() {
  echo "📦 Checking community nodes..."

  mkdir -p "$N8N_DIR/nodes"
  cd "$N8N_DIR/nodes"

  if [ ! -f "package.json" ]; then
    echo "  Creating package.json..."
    npm init -y > /dev/null 2>&1 || true
  fi

  # Add all your community nodes here
  for pkg in "@mookielianhd/n8n-nodes-instagram"; do
    if [ ! -d "node_modules/$pkg" ]; then
      echo "  📥 Installing: $pkg"
      npm install \
        --save \
        --no-audit \
        --no-fund \
        "$pkg" \
        > /dev/null 2>&1 \
      && echo "  ✅ $pkg" \
      || echo "  ⚠️  $pkg failed"
    else
      echo "  ✅ $pkg present"
    fi
  done

  cd "$HOME"
  echo "✅ Community nodes OK"
}

ensure_community_nodes

# ══════════════════════════════════════════════
# DB Schema fix for n8n 2.6.2
# ══════════════════════════════════════════════
fix_db_schema() {
  local db="$1"
  echo "🔧 Checking DB schema (n8n 2.6.2)..."

  # Check user table exists
  local has_user
  has_user=$(sqlite3 "$db" \
    "SELECT count(*) FROM sqlite_master WHERE type='table' AND name='user';" \
    2>/dev/null || echo "0")

  if [ "$has_user" = "0" ]; then
    echo "ℹ️  Fresh DB - no schema fix needed"
    return 0
  fi

  # Check role column in user table
  local has_role
  has_role=$(sqlite3 "$db" \
    "SELECT count(*) FROM pragma_table_info('user') WHERE name='role';" \
    2>/dev/null || echo "0")

  if [ "$has_role" = "0" ]; then
    echo "⚠️  Missing User.role - fixing for n8n 2.6.2..."
    sqlite3 "$db" "
      BEGIN TRANSACTION;
      ALTER TABLE user ADD COLUMN role TEXT NOT NULL DEFAULT 'global:member';
      UPDATE user SET role = 'global:owner'
        WHERE id = (SELECT MIN(id) FROM user);
      UPDATE user SET role = 'global:member' WHERE role IS NULL;
      COMMIT;
    " 2>/dev/null \
    && echo "✅ User.role fixed" \
    || {
      echo "❌ Schema fix failed - backing up and starting fresh"
      mv "$db" "${db}.broken.$(date +%s)" 2>/dev/null || true
      return 1
    }
  else
    echo "✅ User.role exists - schema OK"
  fi

  # Log table summary
  echo "📊 Tables: $(sqlite3 "$db" \
    "SELECT count(*) FROM sqlite_master WHERE type='table';" \
    2>/dev/null || echo '?')"
}

# ══════════════════════════════════════════════
# Restore from Telegram backup
# ══════════════════════════════════════════════
if [ ! -s "$N8N_DIR/database.sqlite" ]; then
  echo "📦 No database - attempting restore..."
  [ -f /scripts/restore.sh ] && \
    sh /scripts/restore.sh 2>&1 || true

  if [ -s "$N8N_DIR/database.sqlite" ]; then
    _tc=$(sqlite3 "$N8N_DIR/database.sqlite" \
      "SELECT count(*) FROM sqlite_master WHERE type='table';" \
      2>/dev/null || echo 0)
    echo "✅ Restored! ($_tc tables)"
    fix_db_schema "$N8N_DIR/database.sqlite"
  else
    echo "🆕 Fresh start - no backup found"
  fi
else
  _sz=$(du -h "$N8N_DIR/database.sqlite" \
    2>/dev/null | cut -f1 || echo "?")
  echo "✅ Database exists ($_sz)"
  fix_db_schema "$N8N_DIR/database.sqlite"
fi

# ══════════════════════════════════════════════
# Clean binaryData on startup
# ══════════════════════════════════════════════
rm -rf "$N8N_DIR/binaryData" 2>/dev/null || true
mkdir -p "$N8N_DIR/binaryData"
echo "🧹 binaryData cleaned"

# ══════════════════════════════════════════════
# Clean old execution records
# ══════════════════════════════════════════════
if [ -s "$N8N_DIR/database.sqlite" ]; then
  echo "🗄️  Cleaning old executions..."
  _before=$(du -h "$N8N_DIR/database.sqlite" \
    2>/dev/null | cut -f1 || echo "?")
  sqlite3 "$N8N_DIR/database.sqlite" "
    DELETE FROM execution_entity WHERE finished = 1;
    DELETE FROM execution_data
      WHERE executionId NOT IN (SELECT id FROM execution_entity);
    VACUUM;
  " 2>/dev/null || true
  _after=$(du -h "$N8N_DIR/database.sqlite" \
    2>/dev/null | cut -f1 || echo "?")
  echo "✅ DB: $_before → $_after"
fi

echo ""

# ══════════════════════════════════════════════
# Background: wait → notify + bot + backup
# ══════════════════════════════════════════════
(
  echo "[bg] Waiting for n8n to be ready..."
  _waited=0
  while [ "$_waited" -lt 180 ]; do
    if curl -sf --max-time 3 \
        "http://localhost:${N8N_PORT}/healthz" \
        > /dev/null 2>&1; then
      echo "[bg] ✅ n8n ready after ${_waited}s"
      break
    fi
    sleep 5
    _waited=$((_waited + 5))
  done

  if [ "$_waited" -ge 180 ]; then
    echo "[bg] ⚠️  n8n did not respond after 180s"
    tg_msg "⚠️ <b>n8n startup timeout!</b>%0ACheck Render logs."
  else
    tg_msg "🚀 <b>n8n 2.6.2 is running!</b>%0ASend /start to control backups."
  fi

  # Start Telegram bot
  if [ -f /scripts/bot.sh ]; then
    sh /scripts/bot.sh 2>&1 | sed 's/^/[bot] /' &
    echo "[bg] ✅ Bot started"
  else
    echo "[bg] ⚠️  bot.sh not found"
  fi

  # Initial backup
  sleep 30
  if [ -s "$N8N_DIR/database.sqlite" ] && \
     [ -f /scripts/backup.sh ]; then
    rm -f "$WORK/.backup_state"
    sh /scripts/backup.sh 2>&1 | sed 's/^/[backup] /' || true
  fi

  # Periodic backup loop
  while true; do
    sleep "$MONITOR_INTERVAL"
    if [ -s "$N8N_DIR/database.sqlite" ] && \
       [ -f /scripts/backup.sh ]; then
      sh /scripts/backup.sh 2>&1 | sed 's/^/[backup] /' || true
    fi
  done
) &

# ══════════════════════════════════════════════
# Keep-alive ping (prevents Render free tier sleep)
# Pings every 4m50s to beat Render 15min timeout
# This keeps Schedule Trigger working 24/7
# ══════════════════════════════════════════════
(
  sleep 90
  echo "[keepalive] Starting - ping every 290s"

  while true; do
    _status=$(curl -sf --max-time 10 \
      "http://localhost:${N8N_PORT}/healthz" \
      2>/dev/null && echo "ok" || echo "fail")

    echo "[keepalive] $(date '+%H:%M:%S') → $_status"

    if [ "$_status" = "fail" ]; then
      tg_msg "⚠️ <b>n8n health check failed!</b>%0AScheduled tasks may be stopped."
    fi

    sleep 290
  done
) &

# ══════════════════════════════════════════════
# Clean binaryData every 10 minutes
# ══════════════════════════════════════════════
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

# ══════════════════════════════════════════════
# Clean DB execution records hourly
# ══════════════════════════════════════════════
(
  sleep 3600
  while true; do
    if [ -s "$N8N_DIR/database.sqlite" ]; then
      sqlite3 "$N8N_DIR/database.sqlite" "
        DELETE FROM execution_entity WHERE finished = 1;
        DELETE FROM execution_data
          WHERE executionId NOT IN (SELECT id FROM execution_entity);
        VACUUM;
      " 2>/dev/null || true
      echo "[db-clean] ✅ cleaned"
    fi
    sleep 3600
  done
) &

# ══════════════════════════════════════════════
# Start n8n (foreground - keeps container alive)
# ══════════════════════════════════════════════
echo "🚀 Starting n8n 2.6.2 on port $N8N_PORT..."
exec n8n start
