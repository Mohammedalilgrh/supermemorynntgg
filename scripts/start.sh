#!/bin/sh
set -e

N8N_DIR="/home/node/.n8n"

mkdir -p "$N8N_DIR"

if [ ! -s "$N8N_DIR/database.sqlite" ]; then
  echo "Restoring from Telegram..."
  sh /scripts/restore.sh || true
fi

n8n start &
N8N_PID=$!

shutdown() {
  echo "Shutdown - backing up..."
  sh /scripts/backup.sh || true
  kill -TERM $N8N_PID 2>/dev/null
  wait $N8N_PID 2>/dev/null
  exit 0
}

trap shutdown SIGTERM SIGINT

wait $N8N_PID
