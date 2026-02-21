#!/bin/bash
set -eu
umask 077

N8N_DIR="${N8N_DIR:-/home/node/.n8n}"
WORK="${WORK:-/backup-data}"
MONITOR_INTERVAL="${MONITOR_INTERVAL:-60}"
N8N_PORT="${N8N_PORT:-5678}"

mkdir -p "$N8N_DIR" "$WORK" "$WORK/history"
export HOME="/home/node"

: "${TG_BOT_TOKEN:?}"
: "${TG_CHAT_ID:?}"
: "${TG_ADMIN_ID:?}"

TG="https://api.telegram.org/bot${TG_BOT_TOKEN}"

log() { echo "[$(date '+%H:%M:%S')] $*"; }

tg_msg() {
  curl -sS --max-time 15 -X POST "${TG}/sendMessage" \
    -d "chat_id=${TG_ADMIN_ID}" \
    -d "parse_mode=HTML" \
    --data-urlencode "text=$1" \
    >/dev/null 2>&1 || true
}

log "=== n8n v6.2 | Node: $(node --version) ==="

# ══════════════════════════════════════════════
# استرجاع DB الخام (بدون إصلاح - n8n سيعمل migrations)
# ══════════════════════════════════════════════
if [ ! -s "$N8N_DIR/database.sqlite" ]; then
  log "📦 استرجاع..."
  tg_msg "🔄 <b>استرجاع...</b>"
  bash /scripts/restore.sh 2>&1 | sed 's/^/[restore] /' || true

  if [ -s "$N8N_DIR/database.sqlite" ]; then
    log "✅ DB مسترجعة"
    tg_msg "✅ <b>تم استرجاع DB</b>"
  else
    log "🆕 أول تشغيل"
    tg_msg "🆕 <b>أول تشغيل</b>"
  fi
else
  log "✅ DB: $(du -h "$N8N_DIR/database.sqlite" | cut -f1)"
fi

# ══════════════════════════════════════════════
# تشغيل n8n (يعمل migrations تلقائياً)
# ══════════════════════════════════════════════
log "🚀 n8n..."
n8n start &
N8N_PID=$!
log "✅ PID: $N8N_PID"

# ══════════════════════════════════════════════
# خلفية: انتظر n8n يكمل migrations ثم أصلح DB
# ══════════════════════════════════════════════
(
  # انتظر n8n يفتح البورت (يعني migrations اكتملت)
  _w=0
  while [ "$_w" -lt 180 ]; do
    curl -sf --max-time 2 "http://localhost:${N8N_PORT}/healthz" \
      >/dev/null 2>&1 && break
    sleep 3
    _w=$((_w + 3))
  done
  log "[bg] ✅ n8n جاهز (${_w}s)"

  # ══════════════════════════════════════════
  # الآن DB فيها كل الـ migrations الجديدة
  # نصلح الـ owner setup
  # ══════════════════════════════════════════
  if [ -s "$N8N_DIR/database.sqlite" ]; then
    _users=$(sqlite3 "$N8N_DIR/database.sqlite" \
      "SELECT count(*) FROM \"user\";" 2>/dev/null || echo 0)

    if [ "$_users" -gt 0 ]; then
      log "[bg] 🔧 إصلاح owner setup بعد migrations..."

      # تشخيص قبل الإصلاح
      _tc=$(sqlite3 "$N8N_DIR/database.sqlite" \
        "SELECT count(*) FROM sqlite_master WHERE type='table';" 2>/dev/null || echo 0)
      _setup_before=$(sqlite3 "$N8N_DIR/database.sqlite" \
        "SELECT value FROM settings WHERE key='userManagement.isInstanceOwnerSetUp';" 2>/dev/null || echo "MISSING")

      log "[bg] جداول بعد migrations: $_tc"
      log "[bg] ownerSetUp قبل: $_setup_before"

      # أوقف n8n مؤقتاً للكتابة على DB بأمان
      kill $N8N_PID 2>/dev/null || true
      sleep 3

      # الإصلاح الشامل
      sqlite3 "$N8N_DIR/database.sqlite" <<'FIXSQL'

-- 1. owner setup flag
DELETE FROM settings WHERE key = 'userManagement.isInstanceOwnerSetUp';
INSERT INTO settings (key, value, "loadOnStartup")
VALUES ('userManagement.isInstanceOwnerSetUp', 'true', 1);

-- 2. تأكد من وجود دور admin
INSERT OR IGNORE INTO role (name, scope, "createdAt", "updatedAt")
SELECT 'admin', 'global', datetime('now'), datetime('now')
WHERE EXISTS (SELECT 1 FROM sqlite_master WHERE type='table' AND name='role');

-- 3. ربط أول مستخدم بدور global admin
INSERT OR IGNORE INTO user_roles ("userId", "roleId")
SELECT u.id, r.id
FROM "user" u, role r
WHERE r.name = 'admin' AND r.scope = 'global'
AND u."createdAt" = (SELECT MIN("createdAt") FROM "user")
AND EXISTS (SELECT 1 FROM sqlite_master WHERE type='table' AND name='user_roles');

-- 4. personal project لكل مستخدم
INSERT OR IGNORE INTO project (id, name, type, "createdAt", "updatedAt")
SELECT
  lower(hex(randomblob(4)) || '-' || hex(randomblob(2)) || '-4' ||
        substr(hex(randomblob(2)),2) || '-a' ||
        substr(hex(randomblob(2)),2) || '-' || hex(randomblob(6))),
  u.email, 'personal', datetime('now'), datetime('now')
FROM "user" u
WHERE NOT EXISTS (
  SELECT 1 FROM project_relation pr
  JOIN project p ON p.id = pr."projectId"
  WHERE pr."userId" = u.id AND p.type = 'personal'
)
AND EXISTS (SELECT 1 FROM sqlite_master WHERE type='table' AND name='project');

-- 5. ربط user بـ personal project
INSERT OR IGNORE INTO project_relation ("projectId", "userId", "role", "createdAt", "updatedAt")
SELECT p.id, u.id, 'project:personalOwner', datetime('now'), datetime('now')
FROM "user" u
JOIN project p ON p.name = u.email AND p.type = 'personal'
WHERE NOT EXISTS (
  SELECT 1 FROM project_relation pr
  WHERE pr."userId" = u.id AND pr."projectId" = p.id
)
AND EXISTS (SELECT 1 FROM sqlite_master WHERE type='table' AND name='project_relation');

FIXSQL

      # تحقق بعد الإصلاح
      _setup_after=$(sqlite3 "$N8N_DIR/database.sqlite" \
        "SELECT value FROM settings WHERE key='userManagement.isInstanceOwnerSetUp';" 2>/dev/null || echo "?")
      _uroles=$(sqlite3 "$N8N_DIR/database.sqlite" \
        "SELECT u.email, r.name, r.scope FROM user_roles ur JOIN \"user\" u ON u.id=ur.\"userId\" JOIN role r ON r.id=ur.\"roleId\";" \
        2>/dev/null || echo "none")
      _projs=$(sqlite3 "$N8N_DIR/database.sqlite" \
        "SELECT type, count(*) FROM project GROUP BY type;" 2>/dev/null || echo "none")

      log "[bg] ownerSetUp بعد: $_setup_after"
      log "[bg] roles: $_uroles"
      log "[bg] projects: $_projs"

      tg_msg "🔧 <b>إصلاح بعد migrations:</b>
📋 جداول: <code>$_tc</code>
🔧 setup: <code>$_setup_before</code> → <code>$_setup_after</code>
👑 roles: <code>$_uroles</code>
📁 projects: <code>$_projs</code>"

      # أعد تشغيل n8n بالـ DB المُصلحة
      log "[bg] 🔄 إعادة تشغيل n8n بالإصلاحات..."
      n8n start &
      N8N_PID=$!
      log "[bg] ✅ n8n PID: $N8N_PID"

      # انتظر يفتح البورت مرة ثانية
      _w2=0
      while [ "$_w2" -lt 120 ]; do
        curl -sf --max-time 2 "http://localhost:${N8N_PORT}/healthz" \
          >/dev/null 2>&1 && break
        sleep 3
        _w2=$((_w2 + 3))
      done
      log "[bg] ✅ n8n جاهز مع الإصلاحات (${_w2}s)"
    fi
  fi

  tg_msg "🚀 <b>n8n جاهز!</b>
🌐 ${WEBHOOK_URL:-}
🤖 /start"

  # ── البوت ──
  log "[bg] 🤖 البوت..."
  while true; do
    bash /scripts/bot.sh 2>&1 | sed 's/^/[bot] /' || true
    sleep 10
  done
) &

# ══════════════════════════════════════════════
# باك أب
# ══════════════════════════════════════════════
(
  sleep 180
  bash /scripts/backup.sh 2>&1 | sed 's/^/[backup] /' || true
  while true; do
    sleep "$MONITOR_INTERVAL"
    [ -s "$N8N_DIR/database.sqlite" ] && \
      bash /scripts/backup.sh 2>&1 | sed 's/^/[backup] /' || true
  done
) &

# ══════════════════════════════════════════════
# Keep-Alive
# ══════════════════════════════════════════════
(
  while true; do
    sleep 200
    curl -sS --max-time 10 -o /dev/null \
      "http://localhost:${N8N_PORT}/healthz" 2>/dev/null || true
  done
) &

# ══════════════════════════════════════════════
# مراقب n8n
# ══════════════════════════════════════════════
log "👀..."
while true; do
  sleep 5
  if ! kill -0 $N8N_PID 2>/dev/null; then
    log "⚠️ restart..."
    sleep 5
    n8n start &
    N8N_PID=$!
    log "✅ PID: $N8N_PID"
  fi
done
