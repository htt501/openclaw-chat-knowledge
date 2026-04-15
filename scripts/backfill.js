#!/usr/bin/env node
/**
 * Backfill historical chat messages from Feishu (up to 3 months)
 * Uses OpenClaw CLI to fetch messages in batches
 */

import { initPool, insertMessage, getStats } from '../src/db.js';

const CHAT_ID = 'oc_7b975ce73644030ddb8a284335af7002';
const CHAT_NAME = 'Z战队';
const BATCH_SIZE = 50;
const MAX_PAGES = 20; // 20 pages × 50 = 1000 messages max per run

async function fetchPage(pageToken) {
  const { execSync } = await import('node:child_process');
  const tokenParam = pageToken ? `, page_token: "${pageToken}"` : '';
  const msg = `用 feishu_im_user_get_messages 获取群 ${CHAT_ID} 的历史消息（page_size: ${BATCH_SIZE}${tokenParam}）。只返回 JSON 格式：{"messages": [{message_id, sender_id, sender_name, content, send_time}], "page_token": "下一页token或null", "has_more": true/false}。不要解释。`;

  try {
    const result = execSync(
      `openclaw agent --agent main --message '${msg.replace(/'/g, "\\'")}' --json --timeout 90`,
      { encoding: 'utf-8', timeout: 120000 }
    );
    const match = result.match(/\{[\s\S]*"messages"[\s\S]*\}/);
    if (match) return JSON.parse(match[0]);
  } catch (err) {
    console.error('Fetch failed:', err.message?.slice(0, 100));
  }
  return null;
}

async function backfill() {
  initPool();
  const before = await getStats();
  console.log(`Before: ${before.total} messages in DB`);
  console.log('Starting historical backfill...');

  let pageToken = null;
  let totalCollected = 0;
  let page = 0;

  while (page < MAX_PAGES) {
    page++;
    console.log(`Page ${page}/${MAX_PAGES}...`);

    const data = await fetchPage(pageToken);
    if (!data || !data.messages || data.messages.length === 0) {
      console.log('No more messages');
      break;
    }

    let pageCollected = 0;
    for (const msg of data.messages) {
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
        if (r) pageCollected++;
      } catch { /* duplicate, skip */ }
    }

    totalCollected += pageCollected;
    console.log(`  Page ${page}: ${pageCollected} new / ${data.messages.length} fetched`);

    if (!data.has_more || !data.page_token) break;
    pageToken = data.page_token;

    // Rate limit
    await new Promise(r => setTimeout(r, 3000));
  }

  const after = await getStats();
  console.log(`\nBackfill complete: ${totalCollected} new messages`);
  console.log(`DB now: ${after.total} messages`);
  return { collected: totalCollected, total: after.total };
}

backfill().then(r => {
  console.log('Done:', r);
  process.exit(0);
}).catch(err => {
  console.error('Backfill failed:', err);
  process.exit(1);
});
