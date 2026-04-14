#!/usr/bin/env node
/**
 * AI analysis pipeline — classify topics, extract decisions/risks, generate embeddings
 * Uses LiteLLM proxy (OpenAI compatible) for classification
 * Uses local Ollama for embeddings
 */

import { initPool, getUnanalyzed, markAnalyzed, insertDecision, insertTodo, insertRisk, updateEmbedding } from '../src/db.js';
import { getEmbedding } from '../src/embedding.js';

const LITELLM_URL = 'http://litellm-alb-1287056927.us-east-1.elb.amazonaws.com/v1/chat/completions';
const LITELLM_KEY = 'sk-78nXoBVKz7XalDcDmb0Lyg';
const MODEL = 'us.anthropic.claude-sonnet-4-5-20250929-v1:0';
const BATCH_SIZE = 10;

async function callLLM(prompt) {
  try {
    const resp = await fetch(LITELLM_URL, {
      method: 'POST',
      headers: { 'Authorization': `Bearer ${LITELLM_KEY}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        model: MODEL,
        max_tokens: 2000,
        messages: [{ role: 'user', content: prompt }]
      })
    });
    if (!resp.ok) return null;
    const data = await resp.json();
    return data.choices?.[0]?.message?.content || null;
  } catch { return null; }
}

async function analyzeBatch(messages) {
  const prompt = `分析以下${messages.length}条飞书群聊消息。对每条消息输出JSON：
{"topics": ["话题标签"], "risk_level": "low/medium/high", "sentiment": "positive/neutral/negative", "decisions": [{"content":"决策内容","rationale":"理由"}], "todos": [{"content":"待办","assignee":"负责人"}], "risks": [{"content":"风险","severity":"low/medium/high"}]}

注意：大部分消息是普通对话，decisions/todos/risks 为空数组即可。只有明确的决策、任务分配、风险才提取。

${messages.map((m, i) => `[消息${i + 1}] 发送者：${m.sender_name} 时间：${m.send_time}\n${m.content}`).join('\n\n')}

输出JSON数组（${messages.length}个元素）：`;

  const result = await callLLM(prompt);
  if (!result) return null;

  try {
    const match = result.match(/\[[\s\S]*\]/);
    return match ? JSON.parse(match[0]) : null;
  } catch { return null; }
}

async function run() {
  initPool();
  console.log('Starting AI analysis...');

  const pending = await getUnanalyzed(100);
  if (pending.length === 0) {
    console.log('No messages to analyze');
    return { analyzed: 0 };
  }

  console.log(`Found ${pending.length} unanalyzed messages`);
  let analyzed = 0;

  for (let i = 0; i < pending.length; i += BATCH_SIZE) {
    const batch = pending.slice(i, i + BATCH_SIZE);
    console.log(`Analyzing batch ${Math.floor(i / BATCH_SIZE) + 1}...`);

    const results = await analyzeBatch(batch);
    if (!results || results.length !== batch.length) {
      console.warn(`Batch analysis returned ${results?.length ?? 0} results for ${batch.length} messages, skipping`);
      continue;
    }

    for (let j = 0; j < batch.length; j++) {
      const msg = batch[j];
      const r = results[j];
      if (!r) continue;

      await markAnalyzed(msg.message_id, r.topics || [], r.risk_level || 'low', r.sentiment || 'neutral');

      for (const d of r.decisions || []) {
        if (d.content) await insertDecision(msg.message_id, d.content, d.rationale, msg.sender_name);
      }
      for (const t of r.todos || []) {
        if (t.content) await insertTodo(msg.message_id, t.content, t.assignee, null);
      }
      for (const risk of r.risks || []) {
        if (risk.content) await insertRisk(msg.message_id, risk.content, risk.severity || 'medium');
      }

      // Generate embedding
      const emb = await getEmbedding(msg.content);
      if (emb) await updateEmbedding(msg.message_id, emb);

      analyzed++;
    }

    // Rate limit: wait 2s between batches
    if (i + BATCH_SIZE < pending.length) await new Promise(r => setTimeout(r, 2000));
  }

  console.log(`Analyzed ${analyzed} messages`);
  return { analyzed, total: pending.length };
}

run().then(r => {
  console.log('Done:', r);
  process.exit(0);
}).catch(err => {
  console.error('Analysis failed:', err);
  process.exit(1);
});
