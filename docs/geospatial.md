# Geospatial conversation presence

This branch adds validated opt-in location data, server-controlled expiry,
continuous attendee location updates, and geographic filters on
`GET /querysession` and authenticated `POST /matches`. `/querysession` retains its
single synthetic-document allowlist. `/matches` retains attendee authentication and
the existing sharing and conference checks.

## Continuous attendee location

Location is stored per attendee in the `attendee-locations` index, one document
each. Every update replaces that document, so the backend keeps no movement
history. A location expires five minutes after its last update, and a background
pass deletes expired documents about once a minute.

Create the index once, before deploying, from `backend/mappings/attendee-locations.json`.
In Kibana Dev Tools run `PUT /attendee-locations` with that file's contents as the
body. The runtime API key needs `read`, `write` and `view_index_metadata` on it.
Until it exists, `PUT /me/location` returns 503, and `/matches` works without places.

### PUT /me/location

Requires the attendee token. The app sends this about once a minute while location
sharing is on. Only send `location_consent: true` if the attendee agreed.

```json
{
  "location_consent": true,
  "location": {"lat": 40.76081, "lon": -111.89106},
  "accuracy_m": 12,
  "venue_id": "conference-center",
  "room_id": "room-a",
  "floor": "1",
  "show_handle": false
}
```

`location_consent`, `location` and `accuracy_m` are required. `venue_id`, `room_id`,
`zone_id` and `floor` are optional. `show_handle` defaults to false.

Response 200: `{"updated_at": "...", "expires_at": "...", "show_handle": false}`.

### DELETE /me/location

Requires the attendee token. Call this when the attendee turns sharing off. It
removes the location immediately and returns 204, even if there was none.

### How /matches uses location

A match includes `place` only while its author has an active location, and only for
recordings they have already shared. Coordinates are rounded to four decimal places
(about 11 meters). `handle` appears only if the author sent `show_handle: true`.

```json
{
  "id": "6f1c...-0000000000",
  "excerpt": "We compared Kubernetes autoscaling strategies.",
  "topics": [],
  "updated_at": "2026-11-09T20:00:00Z",
  "score": 0.89,
  "similarity": 0.78,
  "place": {"lat": 40.7608, "lon": -111.8911, "accuracy_m": 12, "room_id": "room-a", "updated_at": "2026-11-09T20:05:00Z"},
  "handle": "bob"
}
```

Geographic filters on `/matches` apply to authors' current locations, and `radius_m`
must be at least 50. Anyone holding an attendee token for the conference can see the
`place` of attendees with a shared recording, and handles are self-service, so a
token does not prove attendance.

The sections below describe the separate per-conversation `presence` field, which
`/querysession` still reads and nothing writes yet.

Compatibility was reviewed against `origin/main` at `184b12f`, including the
realtime transcript and shared-conversation matching changes. The public route
now lives in `backend/session_search.py`; `backend/main.py` keeps the current app
factory, authentication, lifecycle, and redacted validation handling.

## Data and access patterns

Each conversation can carry one `presence` object. This is the conversation's
shared location, not a person's live location or movement history.

| Field | Type | Purpose |
| --- | --- | --- |
| `shared` | boolean | Require explicit location-sharing consent for discovery |
| `venue_id`, `room_id`, `zone_id`, `floor` | keyword | Exact filters; future grouping by room or zone |
| `location` | geo_point | Optional latitude/longitude for radius search |
| `accuracy_m` | float | Report device uncertainty; future quality filtering |
| `source` | keyword | Distinguish `manual_room`, `qr`, and `device` |
| `updated_at` | date | Display freshness and exclude future-dated presence |
| `expires_at` | date | Exclude expired presence |

The mapping lives in `backend/mappings/conversation-presence.json`. It adds only
the `presence` object, with strict fields, to the existing `conversations` index.
It does not change the transcript embedding model or existing field types.
Serverless manages shard and replica counts, so these are omitted.

`server/elastic/schema.mjs` imports the same presence definition when creating
new indices. Its setup verifier checks nested mapping fields recursively. On an
existing index without presence, setup requires the explicit additive migration
below; it does not mutate an existing schema automatically. The separate service
vector API (`backend/schema.py` and `POST /search`) uses a different schema and
is unchanged by this feature.

With the Elastic CLI configured for the intended project, first inspect its
mapping. Review any existing `presence` field for compatibility. A conflicting
field type needs a new index and reindex migration; do not overwrite it.

```powershell
elastic.cmd es info
elastic.cmd es indices get-mapping --index conversations
elastic.cmd es indices put-mapping --index conversations --input-file backend/mappings/conversation-presence.json --dry-run
# Apply as part of the database rollout, then verify:
elastic.cmd es indices put-mapping --index conversations --input-file backend/mappings/conversation-presence.json
elastic.cmd es indices get-mapping --index conversations
```

No live mapping change has been made as part of this branch's local implementation.
Before the mapping exists, geographic searches return no matches (radius queries
use `ignore_unmapped`); ordinary topic searches continue to work.

## Check-in preparation

`ConversationCheckIn` requires a strict boolean `location_consent: true`.
Manual and QR check-ins require a room or zone; device check-ins require valid
coordinates and accuracy. Clients cannot supply presence timestamps. A future
presence write handler must reuse the existing attendee authentication, derive
ownership from the token, verify participant consent, and verify that the selected
room/zone belongs to the venue before using this helper. Conference IDs in search
parameters are filters; `/matches` additionally checks authenticated membership.

```python
from datetime import datetime, timezone
from backend.geospatial import ConversationCheckIn, build_presence

check_in = ConversationCheckIn(
    location_consent=True,
    venue_id="conference-center",
    room_id="room-a",
    floor="1",
    source="manual_room",
)
presence = build_presence(
    check_in,
    conversation_expires_at=datetime(2026, 11, 10, 1, tzinfo=timezone.utc),
)
```

The example deadline must be replaced by the server's future retention deadline.
Presence defaults to five minutes, allows a server-selected TTL of 1–900 seconds,
and never outlives its conversation. Renew only on a new explicit check-in.
Transcript updates must preserve the existing timestamp rather than renew it.

The current attendee transcript writer uses sequence-number/primary-term guards,
idempotent revision checks, and immutable finalized segments. Presence persistence
must respect those rules; do not introduce the older Node adapter's external
versioning into this path. A presence handler for finalized, shared segments can
follow the ownership and concurrency checks in `backend/attendee/sharing.py`.
Replacing presence must remove fields absent from the new check-in (for example,
old GPS coordinates after a room-only check-in). Checkout must clear presence or
set `shared` to false. Semantic-document updates can re-run inference, so account
for that cost when implementing persistence. This coordination remains unimplemented.

Expiry filters hide records; they do not physically delete stored location data.
The service vector API has its own cleanup task, which does not clean up the
attendee `conversations` index. Presence/attendee retention cleanup remains to be
wired for that index.

## Search contract

Existing `GET /querysession?topic=local%20AI` requests retain their response shape.
`POST /matches` accepts the same optional geographic fields in its JSON body:

- `conference`: exact conference filter; required with any geographic filter.
- `venue_id`, `room_id`, `zone_id`, `floor`: exact identifiers. Room, zone and floor
  require `venue_id`, so common room names cannot match across venues.
- `lat`, `lon`, `radius_m`: must be supplied together. Radius is greater than zero
  and at most 10,000 meters. Coordinates must be finite and within valid bounds.

Examples (the configured synthetic fixture must have matching, fresh presence):

```text
/querysession?topic=local%20AI&conference=__setup_smoke__&venue_id=demo&room_id=room-a
/querysession?topic=local%20AI&conference=__setup_smoke__&lat=40.7608&lon=-111.8910&radius_m=100
```

For authenticated matching, send an attendee bearer token and a body such as:

```json
{
  "conference": "cnh",
  "interests": "local AI",
  "venue_id": "conference-center",
  "room_id": "room-a"
}
```

`/matches` also requires a conference-visible, consenting, finalized transcript
and excludes the requester's own recordings. Geographic filters never relax those
conditions. Matches whose author has no active location still appear in ordinary
matching; they are excluded only when a geographic filter is requested. Saved-profile
interests continue to work when `interests` is omitted.

All geographic conditions combine with AND. Searches require shared, unexpired
presence, a non-future update time, and an unexpired conversation. Documents
without presence are excluded. Semantic relevance still determines ordering;
this version does not sort by distance or calculate walking routes. Radius is
geographic distance and does not establish a room or floor match.

Synthetic geographic `/querysession` results include `presence` alongside `id`,
`conference`, and `transcript`. Non-geographic responses omit presence.
`/matches` exposes `place` and `handle` only as described in Continuous attendee
location. Invalid query combinations return a redacted 422
before executing a search. Attendee authentication may still read the token record.

The current Flutter client uses attendee content search for talks/moments and the
legacy synthetic route for smoke checks. It does not yet send geographic filters
or connect the new `/matches` route to location controls. `GET /search` (content
search) and the service-only `POST /search` have no new geographic parameters.

## Verification and next integration steps

```powershell
python -m venv .venv
.venv/Scripts/python.exe -m pip install -r backend/requirements-dev.txt
.venv/Scripts/python.exe -m ruff check backend
.venv/Scripts/python.exe -m pytest backend/tests -q
node --test server/elastic/store.test.mjs
```

Tests cover check-in consent, coordinates, scope validation, expiry boundaries,
query construction, response compatibility, the synthetic access restriction,
authenticated matching, wrong-conference rejection, and nested mapping validation.
They mock Elasticsearch; a live test still needs a separately scoped synthetic
fixture with fresh presence after the additive mapping is applied. The existing
setup smoke fixture is expired and therefore should not match a geographic query.

Next: creating the `attendee-locations` index, Flutter consent and background
location updates, venue/room lookup, and live Elastic verification. QR scanning, automatic GPS collection, polygons, and heatmaps are
outside this initial slice.

References:
- [Geo-distance query](https://www.elastic.co/docs/reference/query-languages/query-dsl/query-dsl-geo-distance-query)
- [Semantic filtering](https://www.elastic.co/docs/reference/elasticsearch/mapping-reference/semantic-text-reference)
- [Additive mappings](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-indices-put-mapping)
- [Semantic ingestion and updates](https://www.elastic.co/docs/reference/elasticsearch/mapping-reference/semantic-text-ingestions)
