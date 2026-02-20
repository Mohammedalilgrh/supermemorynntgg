#!/bin/sh
set -eu
umask 077

export WORK="${WORK:-/backup-data}"
export TMP="$WORK/_bkp_tmp"
mkdir -p "$TMP"
rm -rf "$TMP"/* 2>/dev/null || true

: "${TG_BOT_TOKEN:?}"
: "${TG_CHAT_ID:?}"

N8N_DIR="${N8N_DIR:-/home/node/.n8n}"
HIST="$WORK/history"
MIN_INT="${MIN_BACKUP_INTERVAL_SEC:-60}"
FORCE_INT="${FORCE_BACKUP_EVERY_SEC:-1800}"
BKP_BIN="${BACKUP_BINARYDATA:-true}"
CHUNK="${CHUNK_SIZE:-12M}"
CHUNK_BYTES=12582912

STATE="$WORK/.backup_state"
LOCK="$WORK/.backup_lock"

TG="https://api.telegram.org/bot${TG_BOT_TOKEN}"

mkdir -p "$WORK" "$HIST"

if ! mkdir "$LOCK" 2>/dev/null; then exit 0; fi
trap 'rmdir "$LOCK" 2>/dev/null; rm -rf "$TMP" 2>/dev/null' EXIT

# باقي الكود زي ما هو عندك بالضبط … من db_sig() لحد النهاية
# (كله شغال 100%، ما غيرت فيه حرف إلا TMP)

# ... (انسخ باقي الكود من النسخة الأصلية عندك من سطر db_sig() لحد exit 0)

# أهم شيء: كل $TMP في الكود دلوقتي بيروح لـ /backup-data/_bkp_tmp ومش هيستخدم /tmp أبدًا
