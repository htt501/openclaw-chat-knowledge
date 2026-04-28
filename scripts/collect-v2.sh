#!/bin/bash
# 聊天记录采集 v2 — lark-cli 自动翻页采集
# Usage: bash collect-v2.sh [months]

PSQL="/opt/homebrew/opt/postgresql@17/bin/psql"
DB="chat_knowledge"
CHAT_ID="oc_7b975ce73644030ddb8a284335af7002"
MONTHS=${1:-6}
START=$(date -v-${MONTHS}m -u +"%Y-%m-%dT00:00:00Z")
LOG=~/.openclaw/logs/chat-collect.log
TMPDIR=$(mktemp -d)

echo "[$(date)] Collecting ${MONTHS} months from ${START}..." >> "$LOG"
echo "Collecting ${MONTHS} months of messages..."

# Fetch all pages
PAGE=0
TOKEN=""
TOTAL_FETCHED=0

while true; do
  PAGE=$((PAGE + 1))
  OUTFILE="$TMPDIR/page_${PAGE}.json"
  
  if [ -z "$TOKEN" ]; then
    lark-cli im +chat-messages-list --chat-id "$CHAT_ID" --page-size 50 --sort asc --start "$START" --format json > "$OUTFILE" 2>/dev/null
  else
    lark-cli im +chat-messages-list --chat-id "$CHAT_ID" --page-size 50 --sort asc --start "$START" --page-token "$TOKEN" --format json > "$OUTFILE" 2>/dev/null
  fi
  
  COUNT=$(python3 -c "import json; d=json.load(open('$OUTFILE')); print(len(d.get('data',{}).get('messages',[])))" 2>/dev/null)
  HAS_MORE=$(python3 -c "import json; d=json.load(open('$OUTFILE')); print(d.get('data',{}).get('has_more',False))" 2>/dev/null)
  TOKEN=$(python3 -c "import json; d=json.load(open('$OUTFILE')); print(d.get('data',{}).get('page_token',''))" 2>/dev/null)
  
  TOTAL_FETCHED=$((TOTAL_FETCHED + ${COUNT:-0}))
  echo "  Page $PAGE: ${COUNT:-0} messages (total: $TOTAL_FETCHED)"
  
  if [ "$HAS_MORE" != "True" ] || [ -z "$TOKEN" ] || [ "$TOKEN" = "None" ]; then
    break
  fi
  
  sleep 1
done

echo "Fetched $TOTAL_FETCHED messages in $PAGE pages. Writing to DB..."

# Parse all pages and write to DB
TMPDIR_COLLECT="$TMPDIR" python3 << 'PYEOF'
import json, subprocess, os, glob

PSQL = '/opt/homebrew/opt/postgresql@17/bin/psql'
DB = 'chat_knowledge'
CHAT_ID = 'oc_7b975ce73644030ddb8a284335af7002'
CHAT_NAME = 'Z战队'
TMPDIR = os.environ.get('TMPDIR_COLLECT', '/tmp')

BOT_APP_IDS = {'cli_a3a28b6ce03bd00e', 'cli_a92f2ed996785bde', 'cli_a92d12ed88385bde', 'cli_a92d0eb0caf89bd3', 'cli_a92d68e588781bd2', 'cli_a93a5e6bc978dbd8', 'cli_a9300a2ac639dbca'}

collected = 0
skipped = 0

for f in sorted(glob.glob(f'{TMPDIR}/page_*.json')):
    try:
        data = json.load(open(f))
        items = data.get('data', {}).get('messages', [])
    except:
        continue
    
    for msg in items:
        sender = msg.get('sender', {})
        sender_type = sender.get('sender_type', '')
        sender_id = sender.get('id', '')
        
        if sender_type == 'app' or sender_id in BOT_APP_IDS:
            skipped += 1
            continue
        
        msg_id = msg.get('message_id', '')
        content = msg.get('content', '')
        create_time = msg.get('create_time', '')
        
        if not msg_id or not content or len(content) < 2:
            skipped += 1
            continue
        
        content_safe = content.replace("'", "''")
        
        sql = f"""INSERT INTO chat_messages (message_id, chat_id, chat_name, sender_id, sender_name, content, send_time)
VALUES ('{msg_id}', '{CHAT_ID}', '{CHAT_NAME}', '{sender_id}', 'TAO', '{content_safe}', '{create_time}')
ON CONFLICT (message_id) DO NOTHING;"""
        
        try:
            r = subprocess.run([PSQL, '-d', DB, '-c', sql], capture_output=True, timeout=5)
            if r.returncode == 0:
                collected += 1
        except:
            pass

print(f'Result: {collected} collected, {skipped} skipped')
PYEOF

# Cleanup
rm -rf "$TMPDIR"
echo "[$(date)] Done" >> "$LOG"
