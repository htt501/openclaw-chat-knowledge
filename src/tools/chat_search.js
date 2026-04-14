/**
 * chat_search — Search chat history (keyword + semantic + time + sender)
 */

import { Type } from '@sinclair/typebox';
import * as db from '../db.js';
import { getEmbedding } from '../embedding.js';

const ChatSearchSchema = Type.Object({
  query: Type.String({ description: '搜索关键词或自然语言问题' }),
  mode: Type.Optional(Type.String({ description: '搜索模式: keyword/semantic/time/sender/decision/risk，默认 keyword' })),
  sender: Type.Optional(Type.String({ description: '按发送者过滤' })),
  days: Type.Optional(Type.Number({ description: '最近 N 天，默认 7' })),
  limit: Type.Optional(Type.Number({ description: '最大返回条数，默认 10' }))
});

export function createChatSearch(logger) {
  return (ctx) => ({
    name: 'chat_search',
    label: 'Chat: Search History',
    parameters: ChatSearchSchema,
    async execute(toolCallId, params) {
      const mode = params.mode || 'keyword';
      const limit = params.limit || 10;
      let results = [];

      try {
        if (mode === 'keyword') {
          results = await db.searchKeyword(params.query, limit);
        } else if (mode === 'semantic') {
          const emb = await getEmbedding(params.query);
          if (emb) {
            results = await db.searchSemantic(emb, limit);
          } else {
            results = await db.searchKeyword(params.query, limit);
          }
        } else if (mode === 'time') {
          const days = params.days || 7;
          const end = new Date();
          const start = new Date(end.getTime() - days * 86400000);
          results = await db.searchByTime(start.toISOString(), end.toISOString(), limit);
        } else if (mode === 'sender') {
          results = await db.searchBySender(params.sender || params.query, limit);
        } else if (mode === 'decision') {
          results = await db.getDecisions(limit);
        } else if (mode === 'risk') {
          results = await db.getRisks(null, limit);
        }

        const formatted = results.map(r => ({
          sender: r.sender_name || r.decision_maker,
          time: r.send_time ? new Date(r.send_time).toLocaleString('zh-CN') : '',
          content: (r.content || r.decision_content || r.risk_content || '').slice(0, 200),
          topics: r.topics,
          chat: r.chat_name
        }));

        logger.info(`chat_search: mode=${mode} query="${params.query}" → ${formatted.length} results`);
        return { content: [{ type: 'text', text: JSON.stringify({ results: formatted, count: formatted.length, mode }) }] };
      } catch (err) {
        logger.error(`chat_search error: ${err.message}`);
        return { content: [{ type: 'text', text: JSON.stringify({ error: err.message }) }] };
      }
    }
  });
}
