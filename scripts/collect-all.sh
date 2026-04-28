#!/bin/bash
# 采集所有群和私聊的消息（排除 Z 战队 bot 消息）
# Usage: bash collect-all.sh [months]

PSQL="/opt/homebrew/opt/postgresql@17/bin/psql"
DB="chat_knowledge"
MONTHS=${1:-6}
LOG=~/.openclaw/logs/chat-collect.log
TMPDIR=$(mktemp -d)
Z_CHAT_ID="oc_7b975ce73644030ddb8a284335af7002"

echo "[$(date)] Collecting all chats (${MONTHS} months)..." >> "$LOG"
echo "Collecting all chats (${MONTHS} months)..."

# Fetch all pages via messages-search (covers all chats)
PAGE=0
TOKEN=""
TOTAL=0

while true; do
  PAGE=$((PAGE + 1))
  OUTFILE="$TMPDIR/page_${PAGE}.json"
  
  if [ -z "$TOKEN" ]; then
    lark-cli im +messages-search --page-size 50 --format json > "$OUTFILE" 2>/dev/null
  else
    lark-cli im +messages-search --page-size 50 --page-token "$TOKEN" --format json > "$OUTFILE" 2>/dev/null
  fi
  
  COUNT=$(python3 -c "import json; d=json.load(open('$OUTFILE')); print(len(d.get('data',{}).get('items',d.get('data',{}).get('messages',[]))))" 2>/dev/null)
  HAS_MORE=$(python3 -c "import json; d=json.load(open('$OUTFILE')); print(d.get('data',{}).get('has_more',False))" 2>/dev/null)
  TOKEN=$(python3 -c "import json; d=json.load(open('$OUTFILE')); print(d.get('data',{}).get('page_token',''))" 2>/dev/null)
  
  TOTAL=$((TOTAL + ${COUNT:-0}))
  echo "  Page $PAGE: ${COUNT:-0} messages (total: $TOTAL)"
  
  if [ "$HAS_MORE" != "True" ] || [ -z "$TOKEN" ] || [ "$TOKEN" = "None" ] || [ "${COUNT:-0}" = "0" ]; then
    break
  fi
  
  sleep 1
done

echo "Fetched $TOTAL messages. Writing to DB..."

# Parse and write
TMPDIR_COLLECT="$TMPDIR" python3 << 'PYEOF'
import json, subprocess, os, glob

PSQL = '/opt/homebrew/opt/postgresql@17/bin/psql'
DB = 'chat_knowledge'
TMPDIR = os.environ.get('TMPDIR_COLLECT', '/tmp')
Z_CHAT_ID = 'oc_7b975ce73644030ddb8a284335af7002'

# Z战队 bot app_ids to exclude
BOT_APP_IDS = {'cli_a3a28b6ce03bd00e', 'cli_a92f2ed996785bde', 'cli_a92d12ed88385bde', 'cli_a92d0eb0caf89bd3', 'cli_a92d68e588781bd2', 'cli_a93a5e6bc978dbd8', 'cli_a9300a2ac639dbca'}

collected = 0
skipped = 0

for f in sorted(glob.glob(f'{TMPDIR}/page_*.json')):
    try:
        data = json.load(open(f))
        items = data.get('data', {}).get('items', data.get('data', {}).get('messages', []))
    except:
        continue
    
    for msg in items:
        sender = msg.get('sender', {}) if isinstance(msg.get('sender'), dict) else {}
        sender_type = sender.get('sender_type', msg.get('sender_type', ''))
        sender_id = sender.get('id', msg.get('sender_id', ''))
        chat_id = msg.get('chat_id', '')
        chat_name = msg.get('chat_name', '')
        
        # Skip bots in Z战队 group
        if chat_id == Z_CHAT_ID and (sender_type == 'app' or sender_id in BOT_APP_IDS):
            skipped += 1
            continue
        
        # Skip all app/bot senders everywhere
        if sender_type == 'app':
            skipped += 1
            continue
        
        msg_id = msg.get('message_id', '')
        content = msg.get('content', '')
        create_time = msg.get('create_time', msg.get('send_time', ''))
        sender_name = msg.get('sender_name', sender.get('name', 'unknown'))
        
        if not msg_id or not content or len(content) < 2:
            skipped += 1
            continue
        
        content_safe = content.replace("'", "''")
        sender_name_safe = sender_name.replace("'", "''")
        chat_name_safe = chat_name.replace("'", "''") if chat_name else 'unknown'
        
        sql = f"""INSERT INTO chat_messages (message_id, chat_id, chat_name, sender_id, sender_name, content, send_time)
VALUES ('{msg_id}', '{chat_id}', '{chat_name_safe}', '{sender_id}', '{sender_name_safe}', '{content_safe}', '{create_time}')
ON CONFLICT (message_id) DO NOTHING;"""
        
        try:
            r = subprocess.run([PSQL, '-d', DB, '-c', sql], capture_output=True, timeout=5)
            if r.returncode == 0:
                collected += 1
        except:
            pass

print(f'Result: {collected} collected, {skipped} skipped')
PYEOF

rm -rf "$TMPDIR"
echo "[$(date)] Done" >> "$LOG"
