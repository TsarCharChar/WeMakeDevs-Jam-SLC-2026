# Conversation vector backend

The FastAPI server accepts full transcript revisions and uses Elasticsearch Serverless `semantic_text` for embeddings and semantic search. No mobile audio or transcripts are uploaded by this change. The existing public `GET /querysession` endpoint and its synthetic-only `conversations` response remain compatible with the pending Flutter search integration. The new authenticated routes use a separate alias and do not alter the existing `conversations` index.

## Data path

```mermaid
flowchart LR
    Client[Future authenticated app gateway] -->|Full transcript + revision| API[FastAPI]
    API -->|Create or conditional replace| ES[(Elasticsearch conversation alias)]
    ES --> Model[Configured text embedding endpoint]
    Client -->|Typed interests| API
    API -->|Filtered semantic match| ES
    ES -->|Ranked conversations| API
```

`backend/schema.py` defines the reproducible schema. The alias `conversation-garden-conversations` must resolve to exactly one backing index, initially `conversation-garden-conversations-v1`. Serverless manages shard and replica counts. Unknown fields are rejected. The service verifies the mapping before operations; it never silently creates an index or changes an existing mapping.

| Field | Mapping and purpose |
| --- | --- |
| `transcript` | `semantic_text`; full revised text, automatic chunking and embeddings |
| `conference`, `visibility`, `deleted` | Exact search eligibility filters (`keyword`, `keyword`, `boolean`) |
| `conversation_id`, `owner_id` | Opaque identifiers (`keyword`), scoped document identity |
| `revision` | Positive `long`; ordering enforced with Elasticsearch sequence-number/primary-term concurrency control |
| `finalized` | Boolean; seals the transcript against further revisions |
| `created_at`, `updated_at`, `expires_at` | Dates; server timestamps and fixed retention deadline |
| `payload_hash` | Stored-only hash; recognizes identical retries without re-embedding |

The indexing and search `inference_id` values must match. Select a **text_embedding** endpoint for dense vectors; do not mix embedding models in this alias. Changing models or incompatible field types requires a new backing index and re-embedding, followed by a verified alias cutover. Do not overwrite or repurpose an existing index with incompatible mappings.

## Local setup and index provisioning

Requires Python 3.12 and the Elastic CLI. Install dependencies with `python -m pip install -r backend/requirements-dev.txt`. Supply the environment variables in `.env.example` using your environment/secret manager. The application does not automatically load `.env` files. The existing untracked `elastic-cli.json`, if used, must be selected with `ELASTIC_CLI_CONFIG_FILE`; its API key reference resolves from `ELASTICSEARCH_API_KEY`.

Use the CLI to inspect the actual deployment before choosing the embedding endpoint:

```text
elastic es info
elastic es inference get --inference-id _all
elastic es indices get-mapping --index conversation-garden-conversations
```

On Windows, use `elastic.cmd` if PowerShell blocks the npm `.ps1` wrapper. A missing index on the first setup is expected. Any authentication or connectivity failure must be fixed before proceeding. Confirm a `text_embedding` endpoint is available, and use its exact ID below and in `ELASTICSEARCH_INFERENCE_ID`:

```text
python -m backend.manage schema --inference-id YOUR_ENDPOINT_ID --output .buildlog/conversations-create.json
elastic es indices create --input-file .buildlog/conversations-create.json --dry-run
elastic es indices create --input-file .buildlog/conversations-create.json
elastic es indices get-mapping --index conversation-garden-conversations
python -m uvicorn backend.main:app --host 127.0.0.1 --port 8080
```

The schema command only generates JSON; the CLI creates the index and write alias. If the index already exists, inspect/validate it rather than recreating it. The runtime key needs `read`, `write`, and `view_index_metadata` on the conversation alias/backing index, plus the inference privileges required by the selected service. Use a separate provisioning credential for `create_index`/alias administration; never give that credential to the mobile app.

`GET /readyz` reports `vector_search: ready` only after checking schema and alias access. URL/key credentials alone continue to power the existing session search endpoint and leave the new vector API `disabled`. Supplying `ELASTICSEARCH_INFERENCE_ID` or `CONVERSATION_API_TOKEN` activates the new integration; partial/invalid configuration or an unavailable index then returns 503. This check does not prove inference is healthy; a successful ingest and search are required for that.

## Trusted service API

All conversation/search routes require `Authorization: Bearer <CONVERSATION_API_TOKEN>` (a random server-only token of at least 32 characters). This is a **trusted service API**, not an end-user authentication system. Its caller is responsible for deriving `owner_id` and conference membership from authenticated users and collecting participant consent. Never bundle the token or Elasticsearch key in Flutter. All examples below are synthetic.

### Write a revision

`PUT /conversations/<conversation_id>`

```json
{
  "conference": "cnh",
  "owner_id": "opaque-owner-id",
  "revision": 1,
  "transcript": "We are discussing Kubernetes workload autoscaling.",
  "visibility": "conference",
  "finalized": false,
  "expires_at": "REPLACE_WITH_A_FUTURE_ISO8601_TIMESTAMP_WITH_TIMEZONE"
}
```

- IDs allow letters, digits, underscores and hyphens, up to 128 characters. Use a new random conversation ID for each recording.
- Send the complete revised transcript, up to 20,000 characters. Increment `revision` for each changed payload. Coalesce Whisper partials instead of sending every token; each accepted changed revision invokes inference.
- A successful response is `{conversation_id, revision, result}`, where `result` is `created`, `updated`, or `unchanged`. Exact retries do not write or embed again. A reused revision with different content or an older revision returns 409.
- Creation uses `op_type=create`; replacements use `if_seq_no` and `if_primary_term`. A race is reread and revalidated up to three times, preventing an older concurrent request from overwriting newer text. Writes require an alias and wait for refresh before acknowledging searchable content.
- Visibility defaults to `private`. Explicit `conference` visibility makes active or finalized text discoverable within that conference. Set `finalized: true` on the last revision; only identical retries and deletion are accepted afterward.
- Set a future expiry at creation, no more than seven days away. Keep that exact deadline on subsequent revisions. Expired conversations cannot be revived.

### Search typed interests

`POST /search`

```json
{"conference": "cnh", "interests": "scaling container workloads", "limit": 10, "min_score": 0}
```

Interests are 1–500 nonblank characters; limit is 1–50. A semantic `match` on `transcript` uses its configured inference endpoint. Exact conference, conference visibility, non-deleted, and future-expiry filters apply inside the query. There is no user-controlled query DSL or index name. The response is `{conversations: [...]}` with IDs, conference, current revision, transcript, finalization, timestamps and raw relevance score. Empty results are an empty array; timeouts/partial failures return 503. Scores are not probabilities. Tune a nonzero `min_score` using representative relevant and irrelevant examples before presenting matches as recommendations.

### Delete and expire

`DELETE /conversations/<conversation_id>?conference=cnh&owner_id=opaque-owner-id`

Deletion replaces the document with a minimal tombstone, removing text and associated vectors from the current searchable document. It is idempotent for an existing tombstone. Subsequent writes to that identity return 410, even with a higher revision. Unknown identities return 404. The tombstone retains opaque conference/owner/conversation IDs, last revision, deletion flag, and update time indefinitely to prevent replay; this is not complete erasure of identity metadata. Historical segments/backups follow Elasticsearch's storage lifecycle.

Expired content is immediately excluded from search. Each API replica runs a bounded cleanup pass every five minutes, replacing at most 100 expired documents with tombstones, with a 180-second deadline. Concurrency controls make overlapping replicas safe. Backlogs may require more passes. A failed pass logs a generic warning and retries on the next interval. Operators can run one bounded pass using the application image/environment:

```text
python -m backend.manage expire --limit 100
```

## Deployment

`deploy/deployment.yaml` preserves the existing `confellow-elastic` Secret reference and additionally reads an optional, non-GitOps Secret named `app-vector-search`. Provision the latter through Radar in `team-grindset`, with keys named exactly `ELASTICSEARCH_URL`, `ELASTICSEARCH_API_KEY`, `ELASTICSEARCH_INDEX`, `ELASTICSEARCH_INFERENCE_ID`, and `CONVERSATION_API_TOKEN`. Both APIs share the URL/key, so use the existing Elastic project and retain access to the original `conversations` index. Values in `app-vector-search` override duplicate keys from `confellow-elastic`; it may omit URL/key to reuse those credentials. Use the Radar UI for credential values. Never commit a Secret manifest or key. Without the optional Secret, existing session search remains enabled and the new vector routes remain disabled. Once vector-specific configuration is supplied, incomplete configuration fails readiness.

After provisioning the index and Secret, restart the app through Radar and verify readiness, synthetic ingestion and semantic search. The image carries `APP_VERSION` and the root response exposes it for deployment verification. No Elasticsearch pod, PVC, or operator is installed in the team cluster.

## Verification

```text
python -m ruff check backend
python -m pytest backend/tests -q
```

Tests use a mock HTTP transport to exercise the Elasticsearch wire contract, concurrent revisions, duplicate retries, eligibility filters, retention, deletion, input limits and error handling. CI runs these before building the deployment image. They do not measure model quality or prove a live Elasticsearch deployment.

An opt-in integration test is included: set `RUN_ELASTIC_INTEGRATION=1` in the process environment after provisioning, then run `python -m pytest backend/tests/test_live_vectors.py -q`. It creates three synthetic conversations in a unique conference, checks paraphrase ranking, revision ordering and private visibility, then deletes its content in a `finally` block. It leaves only replay-prevention tombstones. Normal CI skips this test and requires no credentials.

For live acceptance, ingest two synthetic conversations with different subjects and `conference` visibility, search using a paraphrase of one subject, verify the relevant result and ranking, then send revision 2 and retry revision 1 (expect 409). Add private/other-conference records and confirm exclusion. Delete the synthetic conversations and confirm search returns no deleted records. Do not upload real recordings for a smoke test.

References: Elastic's [semantic_text configuration](https://www.elastic.co/docs/reference/elasticsearch/mapping-reference/semantic-text), [ingestion/update behavior](https://www.elastic.co/docs/reference/elasticsearch/mapping-reference/semantic-text-ingestions), and [semantic search queries](https://www.elastic.co/docs/reference/elasticsearch/mapping-reference/semantic-text-search-retrieval).
