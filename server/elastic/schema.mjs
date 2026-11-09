// Explicit inference IDs keep indexing and query embeddings compatible.
export const DEFAULT_INFERENCE_ID = '.jina-embeddings-v5-text-small';

export function mappings(inferenceId = DEFAULT_INFERENCE_ID) {
  const keyword = { type: 'keyword' };
  const text = { type: 'text' };
  const date = { type: 'date' };
  const semantic = { type: 'semantic_text', inference_id: inferenceId };
  const common = { conference: keyword, expires_at: date };
  const definitions = {
    conversations: {
      conversation_id: keyword, handle: keyword, revision: { type: 'long' },
      transcript: semantic, topics: keyword, visibility: keyword,
      consent: { type: 'boolean' }, is_final: { type: 'boolean' }, updated_at: date,
    },
    talks: {
      title: text, abstract: text, content: semantic, topics: keyword,
      start: date, end: date, room: keyword, speakers: keyword,
    },
    people: {
      handle: keyword, token_hash: { type: 'keyword', index: false, doc_values: false },
      interests: semantic, topics: keyword, starred_talks: keyword, last_active: date,
    },
    moments: { handle: keyword, source: keyword, gist: semantic, topics: keyword, at: date },
    alerts: { to_handle: keyword, kind: keyword, room: keyword, why: text, at: date, seen: { type: 'boolean' } },
    messages: { room: keyword, handle: keyword, text, at: date },
  };
  return Object.fromEntries(Object.entries(definitions).map(([name, properties]) => [name, {
    mappings: {
      dynamic: 'strict',
      _meta: { application: 'conversation-garden', schema_version: 1 },
      properties: { ...common, ...properties },
    },
  }]));
}
