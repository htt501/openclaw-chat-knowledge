#!/usr/bin/env node
/**
 * Collect chat messages from Feishu via OpenClaw CLI
 * Run via cron or manually: node scripts/collect.js
 */

import { initPool, insertMessage } from '../src/db.js';
import { execSync } from 'node:child_process';

const CHAT_ID = 'oc_7b975ce73644030ddb8a284335af7002';
const CHAT_NAME = 'Z战队';

async function collect() {
  initPool();
  console.log('Collecting messages from Feishu...');

  // Use openclaw CLI to fetch messages (bot-level API, no UAT needed)
  let messages;
  try {
    const result = execSync(
      `openclaw agent --agent main --message "用 feishu_im_user_get_messages 获取群 ${CHAT_ID} 最近 100 条消息，只返回 JSON 数组格式：[{message_id, sender_id, sender_name, content, send_time}]。不要解释，只返回 JSON。" --json --timeout 60`,
      { encoding: 'utf-8', timeout: 90000 }
    );
    // Try to extract JSON array from response
    const match = result.match(/\[[\s\S]*\]/);
    if (match) {
      messages = JSON.parse(match[0]);
    }
  } catch (err) {
    console.error('Failed to fetch via CLI:', err.message);
    console.log('Falling back to empty collection');
    return { collected: 0 };
  }

  if (!messages || !Array.isArray(messages)) {
    console.log('No messages parsed');
    return { collected: 0 };
  }

  let collected = 0;
  for (const msg of messages) {
    if (!msg.content || !msg.message_id) continue;
    try {
      const r = await insertMessage({
        message_id: msg.message_id,
        chat_id: CHAT_ID,
        chat_name: CHAT_NAME,
        sender_id: msg.sender_id || 'unknown',
        sender_name: msg.sender_name || 'unknown',
        content: msg.content,
        message_type: 'text',
        send_time: msg.send_time || new Date().toISOString()
      });
      if (r) collected++;
    } catch (err) {
      // duplicate or error, skip
    }
  }

  console.log(`Collected ${collected} new messages (${messages.length} total fetched)`);
  return { collected, total: messages.length };
}

collect().then(r => {
  console.log('Done:', r);
  process.exit(0);
}).catch(err => {
  console.error('Collection failed:', err);
  process.exit(1);
});
