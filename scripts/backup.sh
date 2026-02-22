#!/bin/sh
set -e

TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"
TG_CHAT_ID="${TG_CHAT_ID:-}"

if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then
  echo "Missing TG credentials"
  exit 0
fi

N8N_DIR="/home/node/.n8n"
TMP="/tmp/backup_$$"

mkdir -p "$TMP"

if [ ! -f "$N8N_DIR/database.sqlite" ]; then
  echo "No database found"
  exit 0
fi

echo "Creating backup..."

# Copy database file
cp "$N8N_DIR/database.sqlite" "$TMP/database.sqlite"

# Compress it
gzip -1 "$TMP/database.sqlite"

if [ ! -s "$TMP/database.sqlite.gz" ]; then
  rm -rf "$TMP"
  exit 1
fi

ID=$(date +"%Y-%m-%d_%H-%M-%S")

echo "Uploading to Telegram..."

# Upload using Node.js
node << 'NODESCRIPT'
const https = require('https');
const fs = require('fs');
const path = require('path');

const token = process.env.TG_BOT_TOKEN;
const chatId = process.env.TG_CHAT_ID;
const filePath = process.env.TMP + '/database.sqlite.gz';
const id = process.env.ID;

const fileData = fs.readFileSync(filePath);
const boundary = '----FormBoundary' + Math.random().toString(36).slice(2);

let body = '';
body += '--' + boundary + '\r\n';
body += 'Content-Disposition: form-data; name="chat_id"\r\n\r\n';
body += chatId + '\r\n';
body += '--' + boundary + '\r\n';
body += 'Content-Disposition: form-data; name="caption"\r\n\r\n';
body += '#n8n_backup ' + id + ' | db.sql.gz\r\n';
body += '--' + boundary + '\r\n';
body += 'Content-Disposition: form-data; name="document"; filename="db.sql.gz"\r\n';
body += 'Content-Type: application/gzip\r\n\r\n';

const bodyEnd = '\r\n--' + boundary + '--\r\n';

const bodyBuffer = Buffer.concat([
  Buffer.from(body),
  fileData,
  Buffer.from(bodyEnd)
]);

const options = {
  hostname: 'api.telegram.org',
  port: 443,
  path: '/bot' + token + '/sendDocument',
  method: 'POST',
  headers: {
    'Content-Type': 'multipart/form-data; boundary=' + boundary,
    'Content-Length': bodyBuffer.length
  }
};

const req = https.request(options, (res) => {
  let data = '';
  res.on('data', (chunk) => { data += chunk; });
  res.on('end', () => {
    try {
      const result = JSON.parse(data);
      if (result.ok && result.result && result.result.message_id) {
        console.log('Backup uploaded, pinning...');
        const pinPath = '/bot' + token + '/pinChatMessage?chat_id=' + chatId + '&message_id=' + result.result.message_id + '&disable_notification=true';
        https.get('https://api.telegram.org' + pinPath, (pinRes) => {
          console.log('Pinned!');
          process.exit(0);
        });
      } else {
        console.log('Upload failed:', data);
        process.exit(1);
      }
    } catch(e) {
      console.log('Error:', e.message);
      process.exit(1);
    }
  });
});

req.on('error', (e) => {
  console.log('Request error:', e.message);
  process.exit(1);
});

req.write(bodyBuffer);
req.end();
NODESCRIPT

rm -rf "$TMP"
echo "Backup complete!"
