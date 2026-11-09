import test from 'node:test';
import assert from 'node:assert/strict';
import { ConversationStore, documentId, setup } from './store.mjs';
import { createClient, ElasticError } from './client.mjs';
import { DEFAULT_INFERENCE_ID, mappings } from './schema.mjs';

const sample = {
  conference: 'hackathon', handle: 'ada', conversationId: 'recording-1',
  transcript: 'We are discussing container orchestration.', revision: 2, consent: true,
  expiresAt: '2099-01-01T00:00:00Z',
};

test('revisions share one document and use strict external versioning', async () => {
  const docs = new Map();
  const store = new ConversationStore(async (method, path, body) => {
    const url = new URL(path, 'https://example.com');
    const old = docs.get(url.pathname);
    if (method === 'GET') {
      assert.equal(url.searchParams.get('_source_includes'), 'revision');
      return { _source: { revision: old?.revision } };
    }
    assert.equal(url.searchParams.get('version_type'), 'external');
    assert.equal(method, 'PUT');
    if (old && old.revision >= body.revision) throw new ElasticError(409, 'version_conflict_engine_exception');
    docs.set(url.pathname, body);
  });
  assert.equal((await store.upsert(sample)).accepted, true);
  assert.equal((await store.upsert({ ...sample, revision: 1, transcript: 'Old partial' })).accepted, false);
  assert.deepEqual(await store.upsert(sample), {
    id: documentId(sample.conference, sample.handle, sample.conversationId),
    accepted: true, revision: sample.revision, duplicate: true,
  });
  assert.equal(docs.size, 1);
  assert.equal([...docs.values()][0].transcript, sample.transcript);
  assert.equal([...docs.values()][0].visibility, 'private');
});

test('document identities cannot collide across conferences or owners', () => {
  const a = documentId('one', 'ada', '1');
  assert.notEqual(a, documentId('two', 'ada', '1'));
  assert.notEqual(a, documentId('one', 'bob', '1'));
  assert.notEqual(documentId('a:b', 'c', 'd'), documentId('a', 'b:c', 'd'));
});

test('invalid or unconsented transcripts never reach Elasticsearch', async () => {
  const store = new ConversationStore(() => assert.fail('Unexpected write'));
  for (const patch of [
    { consent: false }, { revision: 0 }, { revision: 1.5 }, { transcript: '' },
    { transcript: 'x'.repeat(32_001) }, { visibility: 'public' },
    { expiresAt: '2000-01-01' }, { expiresAt: 'bad' }, { topics: [5] },
  ]) await assert.rejects(store.upsert({ ...sample, ...patch }));
});

test('search scopes semantic queries by conference, consent, visibility and expiry', async () => {
  const store = new ConversationStore(async (method, path, body) => {
    assert.equal(path, '/conversations/_search');
    assert.equal(method, 'POST');
    assert.deepEqual(body.query.bool.filter, [
      { term: { conference: 'hackathon' } }, { term: { visibility: 'conference' } },
      { term: { consent: true } }, { range: { expires_at: { gt: 'now' } } },
    ]);
    assert.deepEqual(body.query.bool.must, [{ match: { transcript: 'containers OR *' } }]);
    return { hits: { hits: [{ _id: '1', _score: 0.8, _source: { handle: 'ada' } }] } };
  });
  assert.deepEqual(await store.search({ conference: 'hackathon', interests: 'containers OR *' }), [{ id: '1', score: 0.8, handle: 'ada' }]);
  await assert.rejects(store.search({ conference: '', interests: 'test' }));
  await assert.rejects(store.search({ conference: 'test', interests: 'test', limit: 51 }));
});

test('setup is repeatable and rejects an incompatible inference model', async () => {
  const indices = {};
  const request = async (method, path, body) => {
    if (path.startsWith('/_inference/')) return { endpoints: [{ inference_id: DEFAULT_INFERENCE_ID, task_type: 'text_embedding' }] };
    const name = path.split('/')[1];
    if (method === 'PUT') { indices[name] = body; return {}; }
    if (!indices[name]) throw new ElasticError(404, 'index_not_found_exception');
    return { [name]: indices[name] };
  };
  assert.equal((await setup(request)).filter(r => r.status === 'created').length, 6);
  assert.equal((await setup(request)).filter(r => r.status === 'verified').length, 6);
  indices.conversations.mappings.properties.transcript.inference_id = 'wrong-model';
  await assert.rejects(setup(request), /differs/);
});

test('HTTP client uses API key, rejects Kibana and redacts server errors', async () => {
  const env = { ELASTICSEARCH_URL: 'https://example.es.elastic.cloud', ELASTICSEARCH_API_KEY: 'secret' };
  assert.throws(() => createClient({ ...env, ELASTICSEARCH_URL: 'https://example.kb.elastic.cloud/app' }));
  const request = createClient(env, async (url, options) => {
    assert.equal(options.headers.Authorization, 'ApiKey secret');
    assert.equal(options.redirect, 'error');
    return new Response(JSON.stringify({ error: { type: 'security_exception', reason: 'secret transcript' } }), { status: 403 });
  });
  await assert.rejects(request('GET', '/conversations/_count'), error => error.status === 403 && !error.message.includes('secret transcript'));
});

test('all semantic fields pin one embedding endpoint', () => {
  const fields = Object.values(mappings()).flatMap(index => Object.values(index.mappings.properties));
  const semantic = fields.filter(field => field.type === 'semantic_text');
  assert.equal(semantic.length, 4);
  assert.ok(semantic.every(field => field.inference_id === DEFAULT_INFERENCE_ID));
});
