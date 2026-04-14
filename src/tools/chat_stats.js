/**
 * chat_stats — Chat knowledge system statistics
 */

import { Type } from '@sinclair/typebox';
import * as db from '../db.js';

const ChatStatsSchema = Type.Object({});

export function createChatStats(logger) {
  return (ctx) => ({
    name: 'chat_stats',
    label: 'Chat: Stats',
    parameters: ChatStatsSchema,
    async execute(toolCallId, params) {
      try {
        const stats = await db.getStats();
        logger.info(`chat_stats: ${stats.total} messages, ${stats.analyzed} analyzed`);
        return { content: [{ type: 'text', text: JSON.stringify(stats) }] };
      } catch (err) {
        return { content: [{ type: 'text', text: JSON.stringify({ error: err.message }) }] };
      }
    }
  });
}
