/**
 * PostgreSQL database layer for chat knowledge system
 */

import pg from 'pg';
const { Pool } = pg;

let pool = null;

export function initPool(connStr) {
  pool = new Pool({ connectionString: connStr || 'postgresql://localhost/chat_knowledge' });
  return pool;
}

export function getPool() { return pool; }

export async function insertMessage(msg) {
  const sql = `
    INSERT INTO chat_messages (message_id, chat_id, chat_name, sender_id, sender_name, content, message_type, send_time)
    VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
    ON CONFLICT (message_id) DO NOTHING
    RETURNING id`;
  const r = await pool.query(sql, [msg.message_id, msg.chat_id, msg.chat_name, msg.sender_id, msg.sender_name, msg.content, msg.message_type || 'text', msg.send_time]);
  return r.rows[0] || null;
}

export async function markAnalyzed(messageId, topics, riskLevel, sentiment) {
  await pool.query(
    `UPDATE chat_messages SET analyzed=true, topics=$2, risk_level=$3, sentiment=$4 WHERE message_id=$1`,
    [messageId, topics, riskLevel, sentiment]
  );
}

export async function insertDecision(messageId, content, rationale, maker) {
  await pool.query(
    `INSERT INTO decisions (message_id, decision_content, rationale, decision_maker) VALUES ($1,$2,$3,$4)`,
    [messageId, content, rationale, maker]
  );
}

export async function insertTodo(messageId, content, assignee, deadline) {
  await pool.query(
    `INSERT INTO todos (message_id, todo_content, assignee, deadline) VALUES ($1,$2,$3,$4)`,
    [messageId, content, assignee, deadline]
  );
}

export async function insertRisk(messageId, content, severity) {
  await pool.query(
    `INSERT INTO risks (message_id, risk_content, severity) VALUES ($1,$2,$3)`,
    [messageId, content, severity]
  );
}

export async function updateEmbedding(messageId, embedding) {
  await pool.query(
    `UPDATE chat_messages SET embedding=$2 WHERE message_id=$1`,
    [messageId, `[${embedding.join(',')}]`]
  );
}

export async function searchKeyword(query, limit = 10) {
  const sql = `
    SELECT id, message_id, chat_name, sender_name, content, send_time, topics, risk_level,
           ts_rank(search_vector, plainto_tsquery('simple', $1)) as rank
    FROM chat_messages
    WHERE search_vector @@ plainto_tsquery('simple', $1)
    ORDER BY rank DESC, send_time DESC
    LIMIT $2`;
  const r = await pool.query(sql, [query, limit]);
  return r.rows;
}

export async function searchSemantic(embedding, limit = 10) {
  const sql = `
    SELECT id, message_id, chat_name, sender_name, content, send_time, topics, risk_level,
           1 - (embedding <=> $1::vector) as similarity
    FROM chat_messages
    WHERE embedding IS NOT NULL
    ORDER BY embedding <=> $1::vector
    LIMIT $2`;
  const r = await pool.query(sql, [`[${embedding.join(',')}]`, limit]);
  return r.rows;
}

export async function searchByTime(startTime, endTime, limit = 50) {
  const sql = `
    SELECT id, message_id, chat_name, sender_name, content, send_time, topics, risk_level
    FROM chat_messages
    WHERE send_time BETWEEN $1 AND $2
    ORDER BY send_time DESC LIMIT $3`;
  const r = await pool.query(sql, [startTime, endTime, limit]);
  return r.rows;
}

export async function searchBySender(senderName, limit = 20) {
  const sql = `
    SELECT id, message_id, chat_name, sender_name, content, send_time, topics, risk_level
    FROM chat_messages
    WHERE sender_name ILIKE $1
    ORDER BY send_time DESC LIMIT $2`;
  const r = await pool.query(sql, [`%${senderName}%`, limit]);
  return r.rows;
}

export async function getDecisions(limit = 10) {
  const sql = `
    SELECT d.*, m.sender_name, m.send_time, m.content as message_content
    FROM decisions d JOIN chat_messages m ON d.message_id = m.message_id
    ORDER BY d.created_at DESC LIMIT $1`;
  const r = await pool.query(sql, [limit]);
  return r.rows;
}

export async function getRisks(severity, limit = 10) {
  const sql = severity
    ? `SELECT r.*, m.sender_name, m.send_time FROM risks r JOIN chat_messages m ON r.message_id=m.message_id WHERE r.severity=$1 ORDER BY r.created_at DESC LIMIT $2`
    : `SELECT r.*, m.sender_name, m.send_time FROM risks r JOIN chat_messages m ON r.message_id=m.message_id ORDER BY r.created_at DESC LIMIT $1`;
  const r = severity ? await pool.query(sql, [severity, limit]) : await pool.query(sql, [limit]);
  return r.rows;
}

export async function getUnanalyzed(limit = 50) {
  const sql = `SELECT * FROM chat_messages WHERE analyzed=false ORDER BY send_time LIMIT $1`;
  const r = await pool.query(sql, [limit]);
  return r.rows;
}

export async function getStats() {
  const r = await pool.query(`
    SELECT
      COUNT(*) as total,
      COUNT(*) FILTER (WHERE analyzed) as analyzed,
      COUNT(*) FILTER (WHERE NOT analyzed) as pending,
      COUNT(*) FILTER (WHERE embedding IS NOT NULL) as with_embedding,
      MIN(send_time) as earliest,
      MAX(send_time) as latest
    FROM chat_messages
  `);
  const decisions = await pool.query(`SELECT COUNT(*) as count FROM decisions`);
  const risks = await pool.query(`SELECT COUNT(*) as count FROM risks`);
  return { ...r.rows[0], decisions: decisions.rows[0].count, risks: risks.rows[0].count };
}
