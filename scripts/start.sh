#!/bin/sh
set -e

N8N_DIR="/home/node/.n8n"

mkdir -p "$N8N_DIR"

if [ ! -s "$N8N_DIR/database.sqlite" ]; then
  echo "🔄 Restoring backup..."
  sh /scripts/restore.sh || true
fi

echo "🚀 Starting n8n..."

n8n start &
N8N_PID=$!

shutdown_handler() {
  echo "🛑 Shutdown detected. Backing up..."
  sh /scripts/backup.sh || true
  kill -TERM $N8N_PID
  wait $N8N_PID
  exit 0
}

trap shutdown_handler SIGTERM SIGINT

wait $N8N_PID
