#!/bin/sh
set -e

N8N_DIR="/home/node/.n8n"

mkdir -p "$N8N_DIR"

echo ""
echo "╔══════════════════════════════════════════════╗"
echo "║  n8n + Telegram Backup System                ║"
echo "╚══════════════════════════════════════════════╝"
echo ""

# Restore if no database
if [ ! -s "$N8N_DIR/database.sqlite" ]; then
  echo "📦 No database found - restoring from Telegram..."
  sh /scripts/restore.sh || echo "No backup found, starting fresh"
fi

if [ -s "$N8N_DIR/database.sqlite" ]; then
  echo "✅ Database ready!"
else
  echo "🆕 Starting with fresh database"
fi

echo ""

# Start bot in background
if [ -n "$TG_BOT_TOKEN" ] && [ -n "$TG_ADMIN_ID" ]; then
  echo "🤖 Starting Telegram bot..."
  sh /scripts/bot.sh &
fi

echo "🚀 Starting n8n..."

# Start n8n in background
n8n start &
N8N_PID=$!

# Backup on shutdown
shutdown() {
  echo ""
  echo "🛑 Shutdown detected - creating backup..."
  sh /scripts/backup.sh || true
  kill -TERM $N8N_PID 2>/dev/null
  wait $N8N_PID 2>/dev/null
  exit 0
}

trap shutdown SIGTERM SIGINT

# Wait for n8n
wait $N8N_PID
