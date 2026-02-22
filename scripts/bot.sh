#!/bin/sh
set -e

TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"
TG_ADMIN_ID="${TG_ADMIN_ID:-}"

if [ -z "$TG_BOT_TOKEN" ] || [ -z "$TG_ADMIN_ID" ]; then
  echo "Missing TG_BOT_TOKEN or TG_ADMIN_ID"
  exit 0
fi

echo "🤖 Bot starting..."

# Run bot using Node.js
node << 'BOTSCRIPT'
const https = require('https');
const { execSync } = require('child_process');

const token = process.env.TG_BOT_TOKEN;
const adminId = process.env.TG_ADMIN_ID;
const chatId = process.env.TG_CHAT_ID;

let offset = 0;

function apiCall(method, params = {}) {
  return new Promise((resolve, reject) => {
    const url = new URL('https://api.telegram.org/bot' + token + '/' + method);
    Object.keys(params).forEach(k => url.searchParams.append(k, params[k]));
    
    https.get(url.toString(), (res) => {
      let data = '';
      res.on('data', chunk => data += chunk);
      res.on('end', () => {
        try {
          resolve(JSON.parse(data));
        } catch(e) {
          reject(e);
        }
      });
    }).on('error', reject);
  });
}

function sendMessage(text) {
  return apiCall('sendMessage', {
    chat_id: adminId,
    text: text,
    parse_mode: 'HTML'
  });
}

async function handleCommand(text) {
  const cmd = text.toLowerCase().trim();
  
  if (cmd === '/start' || cmd === '/menu') {
    await sendMessage(`🤖 <b>n8n Backup Bot</b>

<b>Commands:</b>
/status - System status
/backup - Create backup now
/help - Show this menu`);
  }
  
  else if (cmd === '/status') {
    const fs = require('fs');
    const dbPath = '/home/node/.n8n/database.sqlite';
    let dbSize = 'Not found';
    
    if (fs.existsSync(dbPath)) {
      const stats = fs.statSync(dbPath);
      dbSize = (stats.size / 1024).toFixed(1) + ' KB';
    }
    
    await sendMessage(`📊 <b>System Status</b>

🗄️ Database: <code>${dbSize}</code>
⏰ Time: <code>${new Date().toISOString()}</code>
✅ n8n is running`);
  }
  
  else if (cmd === '/backup') {
    await sendMessage('⏳ <b>Creating backup...</b>');
    
    try {
      execSync('sh /scripts/backup.sh', { 
        stdio: 'inherit',
        env: process.env
      });
      await sendMessage('✅ <b>Backup complete!</b>');
    } catch(e) {
      await sendMessage('❌ <b>Backup failed</b>\n\n<pre>' + e.message + '</pre>');
    }
  }
  
  else if (cmd === '/help') {
    await sendMessage(`ℹ️ <b>Help</b>

/status - Check system status
/backup - Create backup now
/start - Show main menu

Your database is automatically backed up to Telegram on every shutdown.`);
  }
}

async function pollUpdates() {
  while (true) {
    try {
      const result = await apiCall('getUpdates', {
        offset: offset,
        timeout: 30
      });
      
      if (result.ok && result.result) {
        for (const update of result.result) {
          offset = update.update_id + 1;
          
          const msg = update.message;
          if (!msg) continue;
          
          const fromId = msg.from?.id?.toString();
          if (fromId !== adminId) continue;
          
          const text = msg.text;
          if (!text) continue;
          
          console.log('Command:', text);
          await handleCommand(text);
        }
      }
    } catch(e) {
      console.log('Poll error:', e.message);
      await new Promise(r => setTimeout(r, 5000));
    }
  }
}

console.log('🤖 Bot ready!');
pollUpdates();
BOTSCRIPT
