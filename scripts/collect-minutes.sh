#!/bin/bash
# 采集飞书会议纪要 — lark-cli minutes +search
# Usage: bash collect-minutes.sh

PSQL="/opt/homebrew/opt/postgresql@17/bin/psql"
DB="chat_knowledge"
LOG=~/.openclaw/logs/chat-collect-minutes.log
TMPDIR=$(mktemp -d)

echo "[$(date)] Collecting meeting minutes..." >> "$LOG"
echo "Collecting meeting minutes..."

# Fetch all pages
PAGE=0
TOKEN=""
TOTAL=0

while true; do
  PAGE=$((PAGE + 1))
  OUTFILE="$TMPDIR/page_${PAGE}.json"
  
  if [ -z "$TOKEN" ]; then
    lark-cli minutes +search --participant-ids me --page-size 15 --format json > "$OUTFILE" 2>/dev/null
  else
    lark-cli minutes +search --participant-ids me --page-size 15 --page-token "$TOKEN" --format json > "$OUTFILE" 2>/dev/null
  fi
  
  COUNT=$(python3 -c "import json; d=json.load(open('$OUTFILE')); print(len(d.get('data',{}).get('items',[])))" 2>/dev/null)
  HAS_MORE=$(python3 -c "import json; d=json.load(open('$OUTFILE')); print(d.get('data',{}).get('has_more',False))" 2>/dev/null)
  TOKEN=$(python3 -c "import json; d=json.load(open('$OUTFILE')); print(d.get('data',{}).get('page_token',''))" 2>/dev/null)
  
  TOTAL=$((TOTAL + ${COUNT:-0}))
  echo "  Page $PAGE: ${COUNT:-0} minutes (total: $TOTAL)"
  
  if [ "$HAS_MORE" != "True" ] || [ -z "$TOKEN" ] || [ "$TOKEN" = "None" ] || [ "${COUNT:-0}" = "0" ]; then
    break
  fi
  sleep 1
done

echo "Fetched $TOTAL minutes. Getting content and writing to DB..."

# Parse, get content for each, write to DB
TMPDIR_COLLECT="$TMPDIR" python3 << 'PYEOF'
import json, subprocess, os, glob, re, html

PSQL = '/opt/homebrew/opt/postgresql@17/bin/psql'
DB = 'chat_knowledge'
TMPDIR = os.environ.get('TMPDIR_COLLECT', '/tmp')

collected = 0
skipped = 0

for f in sorted(glob.glob(f'{TMPDIR}/page_*.json')):
    try:
        data = json.load(open(f))
        items = data.get('data', {}).get('items', [])
    except:
        continue
    
    for m in items:
        token = m.get('token', '')
        if not token:
            skipped += 1
            continue
        
        # Parse display_info for title, keywords, owner, time, duration
        display = html.unescape(m.get('display_info', ''))
        # Remove HTML tags
        display_clean = re.sub(r'<[^>]+>', '', display)
        
        meta = m.get('meta_data', {})
        app_link = meta.get('app_link', '')
        description = meta.get('description', '')
        
        # Extract fields from description: "所有者: TAO 开始时间: 2025.11.21 14:30:24 时长: 1 小时 13 分 6 秒"
        owner_match = re.search(r'所有者:\s*(\S+)', description)
        owner = owner_match.group(1) if owner_match else 'unknown'
        
        time_match = re.search(r'开始时间:\s*([\d.]+\s+[\d:]+)', description)
        start_time = time_match.group(1) if time_match else ''
        
        dur_match = re.search(r'时长:\s*(.+?)$', description)
        duration = dur_match.group(1).strip() if dur_match else ''
        
        # Extract title (first line of display_info)
        title = display_clean.split('\n')[0].strip() if display_clean else ''
        
        # Extract keywords
        kw_match = re.search(r'关键词:\s*(.+?)(?:\n|所有者)', display_clean)
        keywords = kw_match.group(1).strip() if kw_match else ''
        
        # Try to get minute content via lark-cli minutes
        content = ''
        try:
            result = subprocess.run(
                ['lark-cli', 'minutes', 'minutes', 'get', '--minute_token', token, '--format', 'json'],
                capture_output=True, text=True, timeout=10
            )
            if result.returncode == 0:
                cdata = json.loads(result.stdout)
                minute_detail = cdata.get('data', {}).get('minute', {})
                content = minute_detail.get('content', minute_detail.get('transcript', ''))
                if not content:
                    # Try paragraphs
                    paragraphs = minute_detail.get('paragraphs', [])
                    content = '\n'.join(p.get('text', '') for p in paragraphs if p.get('text'))
        except:
            pass
        
        # If no content from API, use display_info as fallback
        if not content:
            content = display_clean
        
        # Write to DB
        title_safe = title.replace("'", "''")
        owner_safe = owner.replace("'", "''")
        keywords_safe = keywords.replace("'", "''")
        content_safe = content.replace("'", "''")[:50000]  # limit 50KB
        desc_safe = description.replace("'", "''")
        
        sql = f"""INSERT INTO meeting_minutes (token, title, owner, start_time, duration, keywords, app_link, description, content)
VALUES ('{token}', '{title_safe}', '{owner_safe}', '{start_time}', '{duration}', '{keywords_safe}', '{app_link}', '{desc_safe}', '{content_safe}')
ON CONFLICT (token) DO NOTHING;"""
        
        try:
            r = subprocess.run([PSQL, '-d', DB, '-c', sql], capture_output=True, timeout=10)
            if r.returncode == 0:
                collected += 1
        except:
            pass

print(f'Result: {collected} collected, {skipped} skipped')
PYEOF

rm -rf "$TMPDIR"
echo "[$(date)] Minutes collection done" >> "$LOG"
