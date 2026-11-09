# Attendee API

Base URL: `https://grindset.cnh.radarhq.io`. All examples are synthetic.

| Endpoint | Auth | Purpose |
| --- | --- | --- |
| `PUT /me` | None to claim a handle, attendee token to update | Create or update a profile |
| `POST /moments` | Attendee token | Publish one approved gist |
| `GET /graph` | Attendee token | Topic nodes and edges |
| `GET /search` | Attendee token | Search talks and moments |
| `GET /feed` | Attendee token | The attendee's own alerts |
| `POST /rooms/{room}/messages` | Attendee token | Say one line in a topic or talk room |
| `GET /rooms/{room}/messages` | Attendee token | Read a room's recent messages and how many people are in it |
| `PUT /transcripts/{stream_id}/segments/{sequence}` | Attendee token | Save a partial or final private transcript segment |
| `GET /transcripts/{stream_id}/segments/{sequence}` | Attendee token | Read the latest saved segment revision |
| `GET /transcripts/{stream_id}` | Attendee token | Read ordered, paginated transcript history |
| `PUT /transcripts/{stream_id}/segments/{sequence}/sharing` | Attendee token | Share or unshare one finalized segment |
| `POST /matches` | Attendee token | Find other attendees' shared transcripts that match interests |

See the [realtime transcript contract](transcript-api.md) for revisions, retries,
append behavior, sharing, matching, privacy and the Flutter integration steps.

`POST /search` is a different API: it is the server-to-server conversation search and needs `CONVERSATION_API_TOKEN`. Never put that token in Flutter.

## Attendee token

The first `PUT /me` for a handle returns `token` once. Store it in secure device storage (for example `flutter_secure_storage`) and send it on later requests:

```text
Authorization: Bearer <token>
```

The server keeps only a hash, so a lost token cannot be recovered and that handle stays locked until its profile expires and is removed. Do not log the token or put it in a URL.

## Errors

Errors are `{"detail": "message"}`, except 422, where `detail` is a list of `{loc, msg, type}`.

| Status | Meaning | What Flutter should do |
| --- | --- | --- |
| 401 | Token missing, invalid or expired | Ask the attendee to set up a profile again |
| 403 | Token is valid but not for that handle or conference | Treat as a bug or a wrong conference |
| 409 | Handle taken, or a concurrent update | Ask for another handle, or retry the update |
| 422 | Invalid input | Show a validation message |
| 503 | Elasticsearch unavailable or not provisioned | Retry later |

## PUT /me

| Field | Rules |
| --- | --- |
| `handle` | Required, 2-32 characters: letters, digits, `_`, `-`, starting with a letter or digit |
| `conference` | Required, letters, digits, `_`, `-`, up to 128 characters |
| `interests` | Optional, up to 1000 characters |
| `topics` | Optional, up to 20, each up to 64 characters; case-variant duplicates are merged |
| `starred_talks` | Optional, up to 100 talk IDs |

Each call replaces the whole profile and extends its expiry to seven days from now, so send every field.

```json
{
  "handle": "ada",
  "conference": "cnh",
  "interests": "eBPF tracing and autoscaling",
  "topics": ["eBPF", "Kubernetes"],
  "starred_talks": ["talk-42"]
}
```

Response `201` when created, `200` when updated. `token` appears only on creation.

```json
{
  "handle": "ada",
  "conference": "cnh",
  "interests": "eBPF tracing and autoscaling",
  "topics": ["eBPF", "Kubernetes"],
  "starred_talks": ["talk-42"],
  "last_active": "2026-11-09T20:00:00+00:00",
  "expires_at": "2026-11-16T20:00:00+00:00",
  "created": true,
  "token": "<store this securely>"
}
```

Without a token an existing handle returns 409. Changing a handle is not supported: claim the new handle without a token instead.

## POST /moments

Requires the token. Call this only after the attendee has approved the text. The handle comes from the token, so do not send one. Unknown fields such as `transcript`, `audio` or `handle` return 422.

| Field | Rules |
| --- | --- |
| `conference` | Required, must match the token's conference |
| `gist` | Required, one line, 1-280 characters |
| `topics` | Required, 1-5, each up to 64 characters |
| `source` | Required, `spoken` or `notes` |
| `approved` | Required, must be `true` |
| `expires_at` | Optional, ISO 8601 with timezone, future and at most seven days away; defaults to seven days |

```json
{
  "conference": "cnh",
  "gist": "Autoscaling on custom metrics is easier than expected.",
  "topics": ["Kubernetes", "Autoscaling"],
  "source": "spoken",
  "approved": true
}
```

Response `201`:

```json
{
  "id": "6f1c2d3e4a5b6c7d8e9f0a1b2c3d4e5f",
  "conference": "cnh",
  "at": "2026-11-09T20:00:00+00:00",
  "expires_at": "2026-11-16T20:00:00+00:00"
}
```

A new moment can take a few seconds to appear in `/graph` and `/search`.

## GET /graph

Requires the token. Query: `conference` (required, must match the token's conference), `limit` (topics, 1-100, default 50).

`GET /graph?conference=cnh`

```json
{
  "conference": "cnh",
  "nodes": [
    {"id": "Kubernetes", "label": "Kubernetes", "count": 9},
    {"id": "eBPF", "label": "eBPF", "count": 4}
  ],
  "edges": [
    {"source": "Kubernetes", "target": "eBPF", "weight": 3}
  ]
}
```

`count` is how many talks and moments have the topic. `weight` is how many have both topics. Edges are undirected, appear once, are sorted by weight, and only connect returned nodes. No attendee data is included. An empty conference returns empty arrays.

## GET /search

Requires the token. Query: `q` (required, 1-200 characters), `conference` (required, must match the token's conference), `limit` (1-50, default 10).

`GET /search?q=eBPF&conference=cnh`

```json
{
  "query": "eBPF",
  "conference": "cnh",
  "mode": "hybrid",
  "results": [
    {
      "type": "talk",
      "id": "talk-42",
      "score": 8.5,
      "topics": ["eBPF"],
      "title": "eBPF in production",
      "abstract": "Tracing without restarts.",
      "speakers": ["Grace"],
      "room": "Hall A",
      "start": "2026-11-10T10:00:00Z",
      "end": "2026-11-10T10:30:00Z"
    },
    {
      "type": "moment",
      "id": "6f1c2d3e4a5b6c7d8e9f0a1b2c3d4e5f",
      "score": 0.7,
      "topics": ["eBPF"],
      "gist": "eBPF makes tracing much cheaper.",
      "source": "spoken",
      "at": "2026-11-09T20:00:00+00:00"
    }
  ]
}
```

Results are best match first. Use `type` to choose the layout, and treat absent fields as not available. Scores are only for ordering. `mode` is `keyword` when semantic search was unavailable; in that mode moments match only on an exact topic. Moments never include the author's handle.

## Rooms

Every topic and talk has one room, so people who share a space can talk: `topic:<name>` or `talk:<id>`. Topic rooms
ignore case, so `topic:eBPF` and `topic:ebpf` are the same room. Percent-encode the room in the path.

### POST /rooms/{room}/messages

Requires the token. The handle comes from the token, so do not send one; unknown fields return 422.

| Field | Rules |
| --- | --- |
| `conference` | Required, must match the token's conference |
| `text` | Required, one line, 1-280 characters |

`POST /rooms/topic:eBPF/messages`

```json
{"conference": "cnh", "text": "Anyone going to the Cilium talk at 11:50?"}
```

Response `201`: `{"id": "...", "room": "topic:ebpf", "at": "2026-11-09T20:00:00+00:00"}`. The message is readable
as soon as the response arrives. Messages expire after seven days.

### GET /rooms/{room}/messages

Requires the token. Query: `conference` (required), `limit` (1-100, default 50), `after` (optional ISO 8601 time with
a timezone: only messages after it).

```json
{
  "room": "topic:ebpf",
  "people": 2,
  "messages": [
    {"id": "...", "text": "Anyone going to the Cilium talk at 11:50?", "at": "2026-11-09T20:00:00+00:00", "author": "guest-11ca1f", "mine": true},
    {"id": "...", "text": "Yes, see you there.", "at": "2026-11-09T20:01:00+00:00", "author": "guest-43fc79", "mine": false}
  ]
}
```

Messages are the newest page, oldest first. To poll, pass the `at` of the last message as `after`. `people` is how
many different attendees have written in the room, counted over the whole room. `author` is a label that is stable
inside one room and different in every other room, so a chat cannot be used to follow someone between rooms. The
handle is never returned. A room nobody has written in returns an empty list.

There is no moderation or rate limit yet.

## GET /feed

Requires the token. Query: `limit` (1-100, default 20), `conference` (optional, must match the token's conference). Alerts always belong to the token's attendee.

`GET /feed?limit=20`

```json
{
  "alerts": [
    {
      "id": "alert-1",
      "kind": "talk",
      "room": "topic:ebpf",
      "why": "Three people who care about eBPF are going to this talk.",
      "seen": false,
      "at": "2026-11-09T20:00:00+00:00"
    }
  ]
}
```

Alerts are newest first. Nothing in the backend writes alerts yet, so this list stays empty until something populates the `alerts` index.
