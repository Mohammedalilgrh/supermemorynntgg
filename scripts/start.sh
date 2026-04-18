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
# Ensure directories exist (Render ephemeral)
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
echo "║   n8n + Telegram Backup  - Starting           ║"
echo "╚══════════════════════════════════════════════╝"
echo ""
echo "📡 Port      : $N8N_PORT"
echo "🗄️  DB        : $N8N_DIR/database.sqlite"
echo "🌍 Timezone  : ${TZ:-UTC}"
echo "🎬 FFmpeg    : $(ffmpeg -version 2>&1 | head -1)"
echo ""

# ══════════════════════════════════════════════
# Restore from Telegram backup
# ══════════════════════════════════════════════
if [ ! -s "$N8N_DIR/database.sqlite" ]; then
  echo "📦 No database found - attempting restore..."
  if [ -f /scripts/restore.sh ]; then
    sh /scripts/restore.sh 2>&1 || true
  fi

  if [ -s "$N8N_DIR/database.sqlite" ]; then
    _tc=$(sqlite3 "$N8N_DIR/database.sqlite" \
      "SELECT count(*) FROM sqlite_master WHERE type='table';" \
      2>/dev/null || echo 0)
    echo "✅ Restored! ($_tc tables found)"
  else
    echo "🆕 Fresh start - no backup found"
  fi
else
  _sz=$(du -h "$N8N_DIR/database.sqlite" 2>/dev/null | cut -f1 || echo "?")
  echo "✅ Database exists ($_sz)"
fi

# ══════════════════════════════════════════════
# Clean binaryData on startup
# ══════════════════════════════════════════════
rm -rf "$N8N_DIR/binaryData" 2>/dev/null || true
mkdir -p "$N8N_DIR/binaryData"
echo "🧹 binaryData cleaned"

# ══════════════════════════════════════════════
# Clean old DB execution records on startup
# ══════════════════════════════════════════════
if [ -s "$N8N_DIR/database.sqlite" ]; then
  echo "🗄️  Cleaning old execution records..."
  _before=$(du -h "$N8N_DIR/database.sqlite" 2>/dev/null | cut -f1 || echo "?")
  sqlite3 "$N8N_DIR/database.sqlite" "
    DELETE FROM execution_entity WHERE finished = 1;
    DELETE FROM execution_data
      WHERE executionId NOT IN (SELECT id FROM execution_entity);
    VACUUM;
  " 2>/dev/null || true
  _after=$(du -h "$N8N_DIR/database.sqlite" 2>/dev/null | cut -f1 || echo "?")
  echo "✅ DB cleaned: $_before → $_after"
fi

echo ""

# ══════════════════════════════════════════════
# Background: wait for n8n → notify + start bot + backup
# ══════════════════════════════════════════════
(
  echo "[bg] Waiting for n8n to be ready..."
  _waited=0
  while [ "$_waited" -lt 180 ]; do
    if curl -sf --max-time 3 \
        "http://localhost:${N8N_PORT}/healthz" \
        > /dev/null 2>&1; then
      echo "[bg] n8n is ready ✅"
      break
    fi
    sleep 5
    _waited=$((_waited + 5))
  done

  tg_msg "🚀 <b>n8n is running!</b>%0ASend /start to control backups."

  # Start Telegram bot
  if [ -f /scripts/bot.sh ]; then
    sh /scripts/bot.sh 2>&1 | sed 's/^/[bot] /' &
    echo "[bg] Bot started"
  else
    echo "[bg] ⚠️  bot.sh not found - skipping"
  fi

  # Initial backup after 30s
  sleep 30
  if [ -s "$N8N_DIR/database.sqlite" ] && [ -f /scripts/backup.sh ]; then
    rm -f "$WORK/.backup_state"
    sh /scripts/backup.sh 2>&1 | sed 's/^/[backup] /' || true
  fi

  # Periodic backup loop
  while true; do
    sleep "$MONITOR_INTERVAL"
    if [ -s "$N8N_DIR/database.sqlite" ] && [ -f /scripts/backup.sh ]; then
      sh /scripts/backup.sh 2>&1 | sed 's/^/[backup] /' || true
    fi
  done
) &

# ══════════════════════════════════════════════
# Background: Keep-alive ping
# ══════════════════════════════════════════════
(
  sleep 60
  while true; do
    curl -sf --max-time 5 \
      "http://localhost:${N8N_PORT}/healthz" \
      > /dev/null 2>&1 || true
    sleep 240
  done
) &

# ══════════════════════════════════════════════
# Background: Clean binaryData every 10 min
# (files older than 10 min)
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
# Background: Clean DB execution records hourly
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
      echo "[db-clean] ✅ execution records cleaned"
    fi
    sleep 3600
  done
) &

# ══════════════════════════════════════════════
# Start n8n (foreground - keeps container alive)
# ══════════════════════════════════════════════
echo "🚀 Starting n8n on port $N8N_PORT..."
exec n8n start
