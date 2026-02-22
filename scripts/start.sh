#!/bin/sh
set -e

N8N_DIR="/home/node/.n8n"

mkdir -p "$N8N_DIR"

# Restore if empty
if [ ! -s "$N8N_DIR/database.sqlite" ]; then
  sh /scripts/restore.sh || true
fi

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
