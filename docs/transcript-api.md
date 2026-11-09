# Realtime transcript API

These attendee-authenticated routes save partial transcripts directly to the existing
Elasticsearch `conversations` index. They do not depend on `CONVERSATION_API_TOKEN`,
the separate vector-store alias, or its readiness flag. Reuse the token returned
by [PUT /me](attendee-api.md); keep it in secure device storage.

## Recording and append contract

A stream is one attendee's ordered collection of recording segments.
Generate a random `stream_id` once and persist it along with the next segment
number. Identifiers allow letters, numbers, underscores and hyphens, up to 128
characters, starting with a letter or number.

Start with segment `0`. Each new recording (or committed chunk of a long
recording) gets the next integer `sequence` in the same stream. Sequences range
from 0 to 2147483647; gaps and out-of-order delivery are allowed. Use one writer
per stream, or coordinate sequence allocation between devices.

Within a segment, each update contains that segment's **complete current text**.
Whisper partials revise earlier words; replacing that segment prevents duplication.
Earlier segments remain in Elasticsearch and appear in sequence order when read.
Do not send the full history again. The backend does not concatenate history into
an ever-growing document.

## PUT /transcripts/{stream_id}/segments/{sequence}

Send `Authorization: Bearer <attendee-token>` and JSON:

```json
{
  "revision": 1,
  "transcript": "The current partial transcript",
  "finalized": false,
  "consent": true
}
```

- `revision`: required integer, 1 through 9223372036854775807, increasing within
  this segment. Revisions may skip numbers when the client coalesces pending text.
- `transcript`: required, 1–20,000 characters after trimming surrounding
  whitespace. No audio. Start another segment before reaching this bound.
- `finalized`: strict boolean, defaults to false. On completion, send the final
  text with a newer revision and `finalized: true`. Finalized segments are immutable.
- `consent`: required boolean true. The app must obtain permission to upload
  transcripts; this field is not a substitute for that user-facing choice.
- Unknown fields are rejected. Ownership, conference, visibility and expiry
  come from the authenticated attendee and backend, never from the request.

Success is HTTP 200:

```json
{
  "stream_id": "device-stream",
  "sequence": 0,
  "revision": 1,
  "result": "created"
}
```

`result` is `created`, `updated`, or `unchanged`. An acknowledgement means
Elasticsearch accepted the write and its refresh completed; this is not an
in-memory queue. A lost response can be retried with the **same revision and
payload**. The retry returns `unchanged` without another write or embedding.
A matching retry also works after finalization.

Database compare-and-set guards prevent concurrent updates from silently
overwriting each other. Stale revisions, changed content at the same revision,
and attempts to edit a finalized segment return 409. On 409, read that segment
to reconcile its revision and state; do not blindly increase the revision.

## GET /transcripts/{stream_id}/segments/{sequence}

Requires the same attendee token. Returns the latest saved revision immediately
using a realtime document read, or 404 when missing/expired:

```json
{
  "sequence": 0,
  "revision": 2,
  "transcript": "The completed recording.",
  "finalized": true,
  "updated_at": "2026-11-09T20:00:00Z",
  "expires_at": "2026-11-16T19:59:00Z"
}
```

## GET /transcripts/{stream_id}?limit=20&after=0

Requires the same attendee token. Omit `after` for the first page. Segments are
ordered by sequence, including current partial segments:

```json
{
  "stream_id": "device-stream",
  "segments": [
    {
      "sequence": 1,
      "revision": 3,
      "transcript": "The next recording.",
      "finalized": true,
      "updated_at": "2026-11-09T20:01:00Z",
      "expires_at": "2026-11-16T20:00:00Z"
    }
  ],
  "next_after": null
}
```

`limit` is 1–50. If `next_after` is non-null, pass it as `after` to fetch the
next page. A cursor is an exclusive sequence number. Re-read a segment separately
to observe changes to an earlier partial. Pagination is not a snapshot; a delayed
upload with an earlier sequence is visible when the client reloads from the start.
Render or join the segments in order to show the accumulated transcript.

## Flutter integration

1. Obtain/store the attendee token, stream ID and next segment number securely.
2. Persist the active segment and its revision in a bounded durable outbox.
3. While recording, coalesce partials and send the latest snapshot around every
   2 seconds. Keep one request in flight and one newer snapshot pending.
4. Retry timeouts/503 with the identical payload and bounded exponential backoff.
   Display pending/offline until the backend acknowledges the matching revision.
5. Send the final revision immediately when transcription finishes. Retain it
   until acknowledged, then clear local pending text and advance the sequence.
6. Read older segments on demand. Never queue a separate upload for every word.

This is realtime HTTP ingestion: uploads can happen during recording without
waiting for its end. It is not a WebSocket/SSE broadcast. Network, index refresh
and semantic inference determine acknowledgement latency, so no fixed subsecond
latency is promised. Text upload does not offload Whisper inference from the device.
The Flutter upload queue is a separate integration task; adding these routes does
not make existing app builds start uploading.

## Privacy, retention and operations

Every read/write is scoped to the token's conference and handle. Documents are
private with consent recorded; no transcript is published through `/moments`,
`/graph` or `/search`. Existing public `/querysession` remains restricted to its
synthetic test document. Successful transcript responses use `Cache-Control:
no-store`. Validation and database errors do not echo submitted text or keys.

Expiry is seven days from a segment's first write and is not extended by updates.
Expired records are hidden on reads; updates return 410. This feature does not
install a physical-deletion job for the existing index. Expiry is an access rule,
not a promise of physical erasure.

No new index or schema migration is needed. `conversation_id` stores a hash of
the stream's ownership and ID followed by a fixed-width sequence; the same value
is the Elasticsearch document ID. This reuses the existing strict mapping and
provides deterministic ordering and idempotency. Each changed transcript is
embedded by the existing `semantic_text` mapping on the server.

Runtime Elasticsearch credentials need `read` and `index` on `conversations`,
in addition to the attendee profile permissions. Keep provisioning privileges
(`auto_configure`, `create_index`, `manage`) out of runtime credentials.
A missing index or failed/partial read returns 503, never a false saved/empty
result. There is no fallback to unauthenticated or server-token uploads.

| Status | Meaning |
| --- | --- |
| 401 | Missing, forged or expired attendee token |
| 404 | Requested segment does not exist for this attendee, or expired |
| 409 | Stale/conflicting revision or finalized segment; reconcile with GET |
| 410 | Segment expired; use a new segment |
| 422 | Invalid ID, sequence, payload, consent or pagination |
| 503 | Storage unconfigured, unprovisioned or unavailable; retry later |

Run `python -m pytest backend/tests -q` for unit/contract tests.
Run `python scripts/smoke-transcripts.py` against the public deployment for a
bounded synthetic write/read check. It creates a unique synthetic attendee and
two short segments, and never prints its token or response bodies.
