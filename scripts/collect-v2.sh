#!/bin/bash
# 聊天记录采集 v2 — 使用 lark-cli 直接拉取，不依赖 agent
# Usage: bash collect-v2.sh [days]

PSQL="/opt/homebrew/opt/postgresql@17/bin/psql"
DB="chat_knowledge"
CHAT_ID="oc_7b975ce73644030ddb8a284335af7002"
CHAT_NAME="Z战队"
DAYS=${1:-1}  # 默认采集最近 1 天
LOG=~/.openclaw/logs/chat-collect.log

echo "[$(date)] Starting collection (last ${DAYS} days)..." >> "$LOG"

# 用 lark-cli 搜索消息，JSON 输出
MESSAGES=$(lark-cli im +messages-search \
  --chat-id "$CHAT_ID" \
  --start-time "$(date -v-${DAYS}d +%s)000" \
  --page-size 50 \
  --page-all \
  --format json 2>/dev/null)

if [ -z "$MESSAGES" ]; then
  echo "[$(date)] No messages fetched" >> "$LOG"
  echo "No messages fetched"
  exit 0
fi

# 解析 JSON，过滤 bot 消息，写入数据库
COLLECTED=0
SKIPPED=0

echo "$MESSAGES" | python3 -c "
import json, sys, subprocess

PSQL = '/opt/homebrew/opt/postgresql@17/bin/psql'
DB = 'chat_knowledge'
CHAT_ID = 'oc_7b975ce73644030ddb8a284335af7002'
CHAT_NAME = 'Z战队'

# Bot open_ids to exclude
BOT_IDS = {
    'ou_7a553d49035adf0799489e3d10607ca7',  # 小吉
    'ou_0420b35824c2dfdb5f725da699bdfbe4',  # 贝吉塔
    'ou_5926ce30d9055a393eb760aba975c678',  # 布尔玛
    'ou_ea7346e0cb6f1bf666cca7be0bfdaa61',  # 维斯
    'ou_9df960e0dfa7b1a1d71839faeda967a1',  # 界王神
    'ou_b4d850e6c7f0ff236de5221d940aae8d',  # 琪琪
    'ou_244a2f68855048e7e4d730deecf6f793',  # 小Q
}

collected = 0
skipped = 0

try:
    data = json.load(sys.stdin)
    items = data if isinstance(data, list) else data.get('items', data.get('messages', []))
except:
    items = []

for msg in items:
    sender_id = msg.get('sender', {}).get('id', msg.get('sender_id', ''))
    sender_type = msg.get('sender', {}).get('sender_type', msg.get('sender_type', ''))
    
    # Skip bot messages
    if sender_type == 'app' or sender_id in BOT_IDS:
        skipped += 1
        continue
    
    msg_id = msg.get('message_id', '')
    content = msg.get('body', {}).get('content', msg.get('content', ''))
    sender_name = msg.get('sender', {}).get('name', msg.get('sender_name', 'unknown'))
    send_time = msg.get('create_time', msg.get('send_time', ''))
    
    if not msg_id or not content or len(content) < 2:
        skipped += 1
        continue
    
    # Escape single quotes for SQL
    content_safe = content.replace(\"'\", \"''\")
    sender_name_safe = sender_name.replace(\"'\", \"''\")
    
    sql = f\"\"\"INSERT INTO chat_messages (message_id, chat_id, chat_name, sender_id, sender_name, content, send_time)
VALUES ('{msg_id}', '{CHAT_ID}', '{CHAT_NAME}', '{sender_id}', '{sender_name_safe}', '{content_safe}', to_timestamp({send_time}::bigint/1000.0))
ON CONFLICT (message_id) DO NOTHING;\"\"\"
    
    try:
        subprocess.run([PSQL, '-d', DB, '-c', sql], capture_output=True, timeout=5)
        collected += 1
    except:
        pass

print(f'Collected: {collected}, Skipped: {skipped}')
" 2>&1

echo "[$(date)] Collection done" >> "$LOG"
