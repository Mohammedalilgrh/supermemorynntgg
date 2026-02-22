#!/bin/sh
set -e

N8N_DIR="/home/node/.n8n"

mkdir -p "$N8N_DIR"

# Restore if needed
if [ ! -s "$N8N_DIR/database.sqlite" ]; then
  sh /scripts/restore.sh || true
fi

# Start bot
sh /scripts/bot.sh &

# Start n8n
n8n start &
N8N_PID=$!

shutdown_handler() {
  sh /scripts/backup.sh || true
  kill -TERM $N8N_PID
  wait $N8N_PID
  exit 0
}

trap shutdown_handler SIGTERM SIGINT

wait $N8N_PID
