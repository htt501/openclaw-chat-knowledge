#!/bin/bash
# 检查 chat_knowledge 数据库数据质量
# 让小吉执行: exec({ command: "bash ~/.openclaw/extensions/openclaw-chat-knowledge/scripts/check-data.sh" })

PSQL="/opt/homebrew/opt/postgresql@17/bin/psql"
DB="chat_knowledge"

echo "=== 聊天记录数据库检查 ==="
echo ""

echo "--- 1. 总览 ---"
$PSQL -d $DB -c "SELECT COUNT(*) as 总消息数, COUNT(DISTINCT sender_name) as 发送者数, MIN(send_time)::date as 最早日期, MAX(send_time)::date as 最新日期 FROM chat_messages;"

echo ""
echo "--- 2. 按发送者统计 ---"
$PSQL -d $DB -c "SELECT sender_name as 发送者, COUNT(*) as 消息数 FROM chat_messages GROUP BY sender_name ORDER BY COUNT(*) DESC;"

echo ""
echo "--- 3. 疑似 bot 消息（需要清理） ---"
$PSQL -d $DB -c "SELECT sender_name, COUNT(*) as 数量 FROM chat_messages WHERE sender_name IN ('app', 'Goku', 'Bulma', '贝吉塔/Vegeta', '布尔玛', '维斯', '界王神', '琪琪', '小Q', 'bot') GROUP BY sender_name ORDER BY COUNT(*) DESC;"

echo ""
echo "--- 4. 空内容消息 ---"
$PSQL -d $DB -c "SELECT COUNT(*) as 空内容数 FROM chat_messages WHERE content IS NULL OR length(content) < 2;"

echo ""
echo "--- 5. 最近 5 条人类消息 ---"
$PSQL -d $DB -c "SELECT substr(content, 1, 80) as 内容预览, sender_name as 发送者, send_time::timestamp(0) as 时间 FROM chat_messages WHERE sender_name NOT IN ('app', 'Goku', 'Bulma', '贝吉塔/Vegeta', '布尔玛', '维斯', '界王神', '琪琪', '小Q', 'bot') AND length(content) > 5 ORDER BY send_time DESC LIMIT 5;"

echo ""
echo "--- 6. 按月统计 ---"
$PSQL -d $DB -c "SELECT to_char(send_time, 'YYYY-MM') as 月份, COUNT(*) as 消息数 FROM chat_messages GROUP BY to_char(send_time, 'YYYY-MM') ORDER BY 月份;"

echo ""
echo "=== 检查完成 ==="
