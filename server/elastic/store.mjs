import { createHash } from 'node:crypto';
import { DEFAULT_INFERENCE_ID, mappings } from './schema.mjs';

function required(value, name, max = 256) {
  if (typeof value !== 'string' || !value.trim() || value.length > max) throw new Error(`Invalid ${name}`);
  return value.trim();
}

export function documentId(conference, handle, conversationId) {
  return createHash('sha256').update(JSON.stringify([conference, handle, conversationId])).digest('hex');
}

export async function setup(request, inferenceId = DEFAULT_INFERENCE_ID) {
  const inference = await request('GET', `/_inference/${encodeURIComponent(inferenceId)}`);
  const endpoint = inference.endpoints?.find(e => e.inference_id === inferenceId);
  if (!endpoint || !['text_embedding', 'embedding'].includes(endpoint.task_type)) {
    throw new Error(`Dense embedding endpoint ${inferenceId} is unavailable. Inspect GET /_inference/_all and set ELASTICSEARCH_INFERENCE_ID.`);
  }
  const results = [];
  for (const [name, definition] of Object.entries(mappings(inferenceId))) {
    let existing;
    try { existing = await request('GET', `/${name}/_mapping`); }
    catch (error) { if (error.status !== 404) throw error; }
    if (existing) {
      const actual = existing[name]?.mappings;
      if (actual?._meta?.application !== 'conversation-garden' || actual?.dynamic !== 'strict') {
        throw new Error(`${name} already exists with an unmanaged schema; refusing to overwrite it.`);
      }
      for (const [field, expected] of Object.entries(definition.mappings.properties)) {
        const found = actual.properties?.[field];
        if (!found || Object.entries(expected).some(([key, value]) => found[key] !== value)) {
          throw new Error(`${name}.${field} differs from the expected mapping; migrate explicitly.`);
        }
      }
      results.push({ index: name, status: 'verified' });
    } else {
      await request('PUT', `/${name}`, definition);
      results.push({ index: name, status: 'created' });
    }
  }
  return results;
}

// Server-only adapter. The caller must derive handle and conference from an
// authenticated session; never trust those identities from a mobile request.
export class ConversationStore {
  constructor(request) { this.request = request; }

  async upsert(input, { refresh = false } = {}) {
    const conference = required(input.conference, 'conference');
    const handle = required(input.handle, 'handle');
    const conversationId = required(input.conversationId, 'conversationId');
    const transcript = required(input.transcript, 'transcript', 32_000);
    if (!Number.isSafeInteger(input.revision) || input.revision < 1) throw new Error('revision must be a positive safe integer');
    if (input.consent !== true) throw new Error('Participant consent is required');
    const visibility = input.visibility ?? 'private';
    if (!['private', 'conference'].includes(visibility)) throw new Error('Invalid visibility');
    if (input.isFinal !== undefined && typeof input.isFinal !== 'boolean') throw new Error('Invalid isFinal');
    const topics = input.topics ?? [];
    if (!Array.isArray(topics) || topics.length > 20) throw new Error('Invalid topics');
    const expires = new Date(input.expiresAt);
    if (!Number.isFinite(expires.getTime()) || expires <= new Date()) throw new Error('expiresAt must be a future timestamp');
    const id = documentId(conference, handle, conversationId);
    const body = {
      conference, handle, conversation_id: conversationId, revision: input.revision,
      transcript, consent: true, visibility, is_final: input.isFinal ?? false,
      topics: [...new Set(topics.map(t => required(t, 'topic', 80).toLowerCase()))],
      updated_at: new Date().toISOString(), expires_at: expires.toISOString(),
    };
    try {
      await this.request('PUT', `/conversations/_doc/${id}?version=${input.revision}&version_type=external&refresh=${refresh ? 'wait_for' : 'false'}`, body);
      return { id, accepted: true, revision: input.revision };
    } catch (error) {
      if (error.status === 409 && error.type === 'version_conflict_engine_exception') {
        return { id, accepted: false, reason: 'stale_or_duplicate_revision' };
      }
      throw error;
    }
  }

  async search({ conference, interests, limit = 10 }) {
    required(conference, 'conference');
    required(interests, 'interests', 2000);
    if (!Number.isInteger(limit) || limit < 1 || limit > 50) throw new Error('limit must be between 1 and 50');
    const result = await this.request('POST', '/conversations/_search', {
      size: limit,
      _source: ['conversation_id', 'handle', 'transcript', 'topics', 'updated_at', 'is_final'],
      query: { bool: {
        must: [{ match: { transcript: interests.trim() } }],
        filter: [
          { term: { conference: conference.trim() } },
          { term: { visibility: 'conference' } },
          { term: { consent: true } },
          { range: { expires_at: { gt: 'now' } } },
        ],
      } },
    });
    return result.hits.hits.map(hit => ({ id: hit._id, score: hit._score, ...hit._source }));
  }
}
