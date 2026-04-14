/**
 * openclaw-chat-knowledge 插件入口
 * Chat history knowledge management system
 */

import { initPool } from './src/db.js';
import { createChatSearch } from './src/tools/chat_search.js';
import { createChatStats } from './src/tools/chat_stats.js';

const plugin = {
  id: 'openclaw-chat-knowledge',
  name: 'Chat Knowledge',
  description: 'Search and analyze Feishu chat history with keyword, semantic, and time-based queries',
  register(api) {
    const runtime = api.runtime;
    const logger = runtime.logging.getChildLogger('chat-knowledge');
    const config = api.config ?? {};
    const pluginConfig = config.plugins?.entries?.['openclaw-chat-knowledge']?.config ?? config;

    const connStr = pluginConfig.connectionString || 'postgresql://localhost/chat_knowledge';
    initPool(connStr);

    api.registerTool(createChatSearch(logger), { name: 'chat_search' });
    api.registerTool(createChatStats(logger), { name: 'chat_stats' });

    logger.info('openclaw-chat-knowledge v1.0.0 initialized');
  }
};

export default plugin;
