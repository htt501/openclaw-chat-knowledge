#!/bin/bash
# AI 分析 v2 — 直接 curl LiteLLM + ollama，不依赖 agent
# Usage: bash analyze-v2.sh [batch_size]

PSQL="/opt/homebrew/opt/postgresql@17/bin/psql"
DB="chat_knowledge"
LITELLM="${LITELLM_URL:-http://litellm-alb-1287056927.us-east-1.elb.amazonaws.com/v1/chat/completions}"
LITELLM_KEY="${LITELLM_KEY:?Error: LITELLM_KEY environment variable is required}"
MODEL="${LITELLM_MODEL:-us.anthropic.claude-sonnet-4-5-20250929-v1:0}"
OLLAMA="http://localhost:11434/api/embeddings"
BATCH=${1:-10}
LOG=~/.openclaw/logs/chat-analyze.log

echo "[$(date)] Starting analysis (batch=$BATCH)..." >> "$LOG"

# Get unanalyzed messages
PENDING=$($PSQL -d $DB -t -A -c "SELECT json_agg(row_to_json(t)) FROM (SELECT message_id, sender_name, content, send_time FROM chat_messages WHERE analyzed=false AND length(content)>5 ORDER BY send_time LIMIT $BATCH) t;")

if [ "$PENDING" = "" ] || [ "$PENDING" = "null" ]; then
  echo "[$(date)] No pending messages" >> "$LOG"
  echo "No messages to analyze"
  exit 0
fi

# Call LiteLLM for classification
PROMPT="分析以下消息，对每条输出JSON：{\"topics\":[],\"risk_level\":\"low/medium/high\",\"sentiment\":\"positive/neutral/negative\",\"decisions\":[{\"content\":\"\",\"rationale\":\"\"}],\"todos\":[{\"content\":\"\",\"assignee\":\"\"}],\"risks\":[{\"content\":\"\",\"severity\":\"\"}]}。大部分消息decisions/todos/risks为空数组。输出JSON数组：\n\n$PENDING"

RESULT=$(curl -s -m 120 "$LITELLM" \
  -H "Authorization: Bearer $LITELLM_KEY" \
  -H "Content-Type: application/json" \
  -d "$(python3 -c "
import json, sys
prompt = '''$PROMPT'''
print(json.dumps({
    'model': '$MODEL',
    'max_tokens': 4000,
    'messages': [{'role': 'user', 'content': prompt}]
}))
")" 2>/dev/null)

if [ -z "$RESULT" ]; then
  echo "[$(date)] LLM call failed" >> "$LOG"
  echo "LLM call failed"
  exit 1
fi

# Parse and update database
python3 -c "
import json, subprocess, sys

PSQL = '/opt/homebrew/opt/postgresql@17/bin/psql'
DB = 'chat_knowledge'
OLLAMA = 'http://localhost:11434/api/embeddings'

result_raw = '''$RESULT'''
pending_raw = '''$PENDING'''

try:
    result = json.loads(result_raw)
    content = result.get('choices', [{}])[0].get('message', {}).get('content', '')
    # Extract JSON array
    import re
    match = re.search(r'\[[\s\S]*\]', content)
    analyses = json.loads(match.group(0)) if match else []
except Exception as e:
    print(f'Parse error: {e}')
    sys.exit(1)

try:
    messages = json.loads(pending_raw)
except:
    messages = []

if len(analyses) != len(messages):
    print(f'Mismatch: {len(analyses)} analyses vs {len(messages)} messages')
    # Try to match what we can
    analyses = analyses[:len(messages)]

analyzed = 0
for i, msg in enumerate(messages):
    if i >= len(analyses):
        break
    a = analyses[i]
    msg_id = msg['message_id']
    topics = '{' + ','.join(a.get('topics', [])) + '}'
    risk = a.get('risk_level', 'low')
    sentiment = a.get('sentiment', 'neutral')
    
    # Update main record
    sql = f\"\"\"UPDATE chat_messages SET analyzed=true, topics='{topics}', risk_level='{risk}', sentiment='{sentiment}' WHERE message_id='{msg_id}';\"\"\"
    subprocess.run([PSQL, '-d', DB, '-c', sql], capture_output=True, timeout=5)
    
    # Insert decisions
    for d in a.get('decisions', []):
        if d.get('content'):
            dc = d['content'].replace(\"'\", \"''\")
            dr = (d.get('rationale') or '').replace(\"'\", \"''\")
            subprocess.run([PSQL, '-d', DB, '-c', f\"INSERT INTO decisions (message_id, decision_content, rationale, decision_maker) VALUES ('{msg_id}', '{dc}', '{dr}', '{msg.get(\"sender_name\",\"\")}');\"], capture_output=True, timeout=5)
    
    # Insert risks
    for r in a.get('risks', []):
        if r.get('content'):
            rc = r['content'].replace(\"'\", \"''\")
            subprocess.run([PSQL, '-d', DB, '-c', f\"INSERT INTO risks (message_id, risk_content, severity) VALUES ('{msg_id}', '{rc}', '{r.get(\"severity\",\"medium\")}');\"], capture_output=True, timeout=5)
    
    # Generate embedding via ollama
    try:
        import urllib.request
        req = urllib.request.Request(OLLAMA, data=json.dumps({'model': 'nomic-embed-text', 'prompt': msg['content'][:2000]}).encode(), headers={'Content-Type': 'application/json'})
        resp = urllib.request.urlopen(req, timeout=10)
        emb = json.loads(resp.read()).get('embedding')
        if emb:
            emb_str = '[' + ','.join(str(x) for x in emb) + ']'
            subprocess.run([PSQL, '-d', DB, '-c', f\"UPDATE chat_messages SET embedding='{emb_str}'::vector WHERE message_id='{msg_id}';\"], capture_output=True, timeout=5)
    except:
        pass
    
    analyzed += 1

print(f'Analyzed: {analyzed}/{len(messages)}')
" 2>&1

echo "[$(date)] Analysis done" >> "$LOG"
