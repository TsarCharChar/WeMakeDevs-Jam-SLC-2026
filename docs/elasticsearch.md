# Elasticsearch setup

The current Flutter MVP needs one document per conversation, replaced by full
Whisper transcript revisions. `server/elastic` implements this database boundary
using Node.js 22+ with no npm dependencies. It does not expose an HTTP server or
connect the Flutter preview to the network. The existing deployed FastAPI service
in `backend/main.py` does not consume this Node.js adapter; API integration is
separate work. The native mobile MVP is tracked in PR #3.

## Project and indices

- Kibana: https://my-vectordb-project-e1e44b.kb.us-central1.gcp.elastic.cloud/app/vectordb
- Elasticsearch: https://my-vectordb-project-e1e44b.es.us-central1.gcp.elastic.cloud:443
- Embedding endpoint: `.jina-embeddings-v5-text-small`, confirmed available in this
  project (Elastic Inference Service, 1024 dimensions, cosine similarity).
- `conversations`: current MVP transcript and search store.
- `talks`, `people`, `moments`, `alerts`, `messages`: mappings from the architecture's
  historical backend sketch, ready for those future features.

The four semantic fields (`transcript`, `content`, `interests`, `gist`) explicitly
pin the same model. Elastic handles chunking, embeddings and vector indexing.
Strict mappings catch accidental schema changes. No raw audio is stored.

Verified in the live project on November 9, 2026: all six indices are open;
indexing a synthetic Kubernetes transcript generated embeddings; querying
`scaling container workloads` returned that document with score `0.7822014`.
Writing revision 1 after revision 2 returned HTTP 409, and search still returned
revision 2. Seven local adapter tests also pass.

One synthetic fixture remains as `conversations/_doc/setup-smoke-20261109`, under
conference `__setup_smoke__`, with private visibility and an already expired
timestamp. Normal discovery excludes it. No real attendee data was uploaded.
No API key was created or copied into the workspace during browser setup.

## Reproduce the setup

Copy `.env.example` to `.env` and populate the **encoded** Elasticsearch API key.
`.env` is ignored by Git. Keep it on the server; never use Flutter dart-defines
for Elastic credentials. The Elasticsearch endpoint contains `.es.`, not `.kb.`.

```powershell
node --env-file-if-exists=.env scripts/elastic.mjs setup
node --env-file-if-exists=.env scripts/elastic.mjs status
node --test server/elastic/store.test.mjs
```

`setup` checks the configured inference endpoint, creates missing indices, and
verifies existing mappings. It fails on incompatible schemas without deleting
anything. To use another dense embedding endpoint, set
`ELASTICSEARCH_INFERENCE_ID` before initially creating the indices. Changing the
model of an existing index requires an explicit reindex migration.

Alternatively, use `docs/elastic-setup.http` in Kibana Dev Tools. Select all
requests and run them. Unlike the setup script, those plain `PUT` requests return
`resource_already_exists_exception` on reruns. Regenerate that file with
`node scripts/elastic.mjs console` after changing the schema or endpoint.

Setup credentials need `monitor_inference` and index `create_index` and
`view_index_metadata` on the six named indices. Runtime credentials need
`read`, `index`, and `view_index_metadata` for `conversations`, plus
`monitor_inference` as needed for inference. Do not grant the mobile client a key.

## Server integration contract

```js
import { createClient } from './server/elastic/client.mjs';
import { ConversationStore } from './server/elastic/store.mjs';

const store = new ConversationStore(createClient());
await store.upsert({
  conference: 'wemakedevs-slc-2026', // derive from authenticated membership
  handle: 'attendee-1',             // derive from authenticated session
  conversationId: 'uuid-per-recording',
  revision: 1,                     // increase for every revised full transcript
  transcript: 'We are comparing Kubernetes autoscaling strategies.',
  consent: true,                   // only after all participants agree
  visibility: 'conference',        // omitted => private, excluded from discovery
  isFinal: false,
  topics: ['kubernetes'],
  expiresAt: '2026-11-10T01:00:00Z', // server-chosen conference retention deadline
});

const matches = await store.search({
  conference: 'wemakedevs-slc-2026',
  interests: 'scaling container workloads',
});
```

The example expiry is illustrative: use a future deadline chosen by the server.
Document IDs hash conference, owner and recording ID. External versioning rejects
old or duplicate revisions atomically, including out-of-order inference results.
Retry a failed request with the same revision and payload. Never reuse a recording
ID after deletion/expiry; Elasticsearch retains deletion version tombstones only
temporarily. Ingestion must reject updates after the server's recording deadline.

Throttle/coalesce Whisper updates in the future server (for example one changed
transcript every few seconds, plus the final transcript). Full replacements run
inference again; embedding every audio callback wastes money and increases load.
Writes default to eventual search visibility; `{ refresh: true }` waits for the
next refresh and is useful in integration checks, not on every live partial.

Discovery includes only consenting, unexpired, conference-visible conversations
in the requested conference. The caller must authenticate conference membership;
these filters do not provide authentication by themselves. Scores are similarities,
not calibrated probabilities. Tune a relevance threshold using real examples
before claiming that every returned result is a useful match.

`expires_at` filters search immediately but **does not delete data**. A scheduled
cleanup job still needs to be wired to delete expired documents. HTTP transport,
session authentication, rate limits, participant consent UI, retention enforcement,
and Flutter upload/search integration remain separate work before real users upload.

## References

- [Semantic field configuration](https://www.elastic.co/docs/reference/elasticsearch/mapping-reference/semantic-text-setup-configuration)
- [Semantic search and filters](https://www.elastic.co/docs/reference/elasticsearch/mapping-reference/semantic-text-reference)
- [External document versioning](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-index)
