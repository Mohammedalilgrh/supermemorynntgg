#!/bin/sh
set -e

TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"
TG_CHAT_ID="${TG_CHAT_ID:-}"

if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_CHAT_ID" ]; then
  echo "Missing TG credentials"
  exit 0
fi

N8N_DIR="/home/node/.n8n"
TMP="/tmp/restore_$$"

mkdir -p "$TMP" "$N8N_DIR"

echo "Looking for pinned backup..."

# Download using Node.js
node << 'NODESCRIPT'
const https = require('https');
const fs = require('fs');
const zlib = require('zlib');

const token = process.env.TG_BOT_TOKEN;
const chatId = process.env.TG_CHAT_ID;
const tmpDir = process.env.TMP;
const n8nDir = process.env.N8N_DIR;

function httpsGet(url) {
  return new Promise((resolve, reject) => {
    https.get(url, (res) => {
      if (res.statusCode >= 300 && res.statusCode < 400 && res.headers.location) {
        return httpsGet(res.headers.location).then(resolve).catch(reject);
      }
      let data = [];
      res.on('data', chunk => data.push(chunk));
      res.on('end', () => resolve(Buffer.concat(data)));
      res.on('error', reject);
    }).on('error', reject);
  });
}

async function main() {
  console.log('Getting chat info...');
  
  const chatInfo = await httpsGet('https://api.telegram.org/bot' + token + '/getChat?chat_id=' + chatId);
  const chatData = JSON.parse(chatInfo.toString());
  
  if (!chatData.ok) {
    console.log('Failed to get chat info');
    process.exit(1);
  }
  
  if (!chatData.result.pinned_message) {
    console.log('No pinned message found');
    process.exit(0);
  }
  
  if (!chatData.result.pinned_message.document) {
    console.log('Pinned message has no document');
    process.exit(0);
  }
  
  const fileId = chatData.result.pinned_message.document.file_id;
  const fileName = chatData.result.pinned_message.document.file_name || 'backup';
  
  console.log('Found pinned file:', fileName);
  
  console.log('Getting file path...');
  const fileInfo = await httpsGet('https://api.telegram.org/bot' + token + '/getFile?file_id=' + fileId);
  const fileData = JSON.parse(fileInfo.toString());
  
  if (!fileData.ok || !fileData.result.file_path) {
    console.log('Could not get file path');
    process.exit(1);
  }
  
  console.log('Downloading backup...');
  const fileContent = await httpsGet('https://api.telegram.org/file/bot' + token + '/' + fileData.result.file_path);
  
  console.log('Downloaded', fileContent.length, 'bytes');
  
  // Check if it's gzipped
  const isGzip = fileContent[0] === 0x1f && fileContent[1] === 0x8b;
  
  let sqlData;
  if (isGzip) {
    console.log('Decompressing...');
    sqlData = zlib.gunzipSync(fileContent);
  } else {
    sqlData = fileContent;
  }
  
  // Check if it's SQL dump or raw SQLite
  const isSqlDump = sqlData.toString('utf8', 0, 100).includes('PRAGMA') || 
                    sqlData.toString('utf8', 0, 100).includes('CREATE') ||
                    sqlData.toString('utf8', 0, 100).includes('INSERT');
  
  if (isSqlDump) {
    console.log('SQL dump detected, writing to temp file...');
    fs.writeFileSync(tmpDir + '/dump.sql', sqlData);
    console.log('SQLDUMP');
  } else {
    console.log('Raw SQLite file detected...');
    fs.writeFileSync(n8nDir + '/database.sqlite', sqlData);
    console.log('RAWDB');
  }
  
  console.log('Restore complete!');
  process.exit(0);
}

main().catch(err => {
  console.error('Error:', err.message);
  process.exit(1);
});
NODESCRIPT

RESULT=$?

# If SQL dump was created, import it
if [ -f "$TMP/dump.sql" ]; then
  echo "Importing SQL dump..."
  
  # Use node to run sqlite commands
  node << 'SQLSCRIPT'
const { execSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const tmpDir = process.env.TMP;
const n8nDir = process.env.N8N_DIR;
const dumpFile = path.join(tmpDir, 'dump.sql');
const dbFile = path.join(n8nDir, 'database.sqlite');

// Remove existing db
if (fs.existsSync(dbFile)) {
  fs.unlinkSync(dbFile);
}

// Read and execute SQL
const sql = fs.readFileSync(dumpFile, 'utf8');

// Use better-sqlite3 which is included in n8n
try {
  const Database = require('better-sqlite3');
  const db = new Database(dbFile);
  db.exec(sql);
  db.close();
  console.log('Database imported successfully!');
} catch (e) {
  console.log('Error importing:', e.message);
  process.exit(1);
}
SQLSCRIPT
fi

rm -rf "$TMP"

# Verify database
if [ -s "$N8N_DIR/database.sqlite" ]; then
  echo "✅ Database restored!"
else
  echo "❌ Database restore failed"
  exit 1
fi
