/**
 * Embedding via local Ollama nomic-embed-text
 */

const OLLAMA_URL = 'http://localhost:11434/api/embeddings';

export async function getEmbedding(text) {
  try {
    const resp = await fetch(OLLAMA_URL, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ model: 'nomic-embed-text', prompt: text.slice(0, 2000) })
    });
    if (!resp.ok) return null;
    const data = await resp.json();
    return data.embedding || null;
  } catch { return null; }
}

export async function getEmbeddings(texts) {
  const results = [];
  for (const t of texts) {
    results.push(await getEmbedding(t));
  }
  return results;
}
