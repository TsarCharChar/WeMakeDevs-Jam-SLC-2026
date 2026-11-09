# Geospatial conversation presence

This branch adds the first backend slice: validated opt-in check-in data,
server-controlled expiry, an additive Elasticsearch mapping, and geographic
filters on the existing `GET /querysession` route. It does not collect phone
location, persist check-ins, expose a write endpoint, or enable attendee discovery.
The route retains its consent filter and single synthetic-document allowlist.

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
authenticated write handler must verify conference membership, conversation
ownership, participant consent, and that the selected room/zone belongs to the
venue before using this helper. Conference IDs in search parameters are filters,
not proof of membership.

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

The intended ingestion integration includes `presence` in the next full
conversation revision and preserves external version ordering. Replacing the
presence object must remove fields absent from the new check-in (for example,
old GPS coordinates after a room-only check-in). Checkout must clear presence or
set `shared` to false in a new revision. Do not naively use partial updates on the
semantic document: they can re-run inference and interfere with the transcript
writer's revision scheme. This persistence coordination remains to be implemented.

Expiry filters hide records; they do not physically delete stored location data.
Retention cleanup remains a separate backend job.

## Search contract

Existing `GET /querysession?topic=local%20AI` requests retain their response shape.
Optional parameters:

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

All geographic conditions combine with AND. Searches require shared, unexpired
presence, a non-future update time, and an unexpired conversation. Documents
without presence are excluded. Semantic relevance still determines ordering;
this version does not sort by distance or calculate walking routes. Radius is
geographic distance and does not establish a room or floor match.

Geographic results include the `presence` object alongside the existing `id`,
`conference`, and `transcript` fields. Non-geographic responses omit presence.
Invalid query combinations return 422 before contacting Elasticsearch.

## Verification and next integration steps

```powershell
python -m venv .venv
.venv/Scripts/python.exe -m pip install -r backend/requirements-dev.txt
.venv/Scripts/python.exe -m unittest discover -s backend/tests -v
```

Tests cover check-in consent, coordinates, scope validation, expiry boundaries,
query construction, response compatibility, and the synthetic access restriction.
They mock Elasticsearch; a live test still needs a separately scoped synthetic
fixture with fresh presence after the additive mapping is applied. The existing
setup smoke fixture is expired and therefore should not match a geographic query.

Next: authenticated ingestion/check-in/checkout persistence, venue/room lookup,
Flutter opt-in check-in and search controls, expiry cleanup, and live Elastic
verification. QR scanning, automatic GPS collection, polygons, and heatmaps are
outside this initial slice.

References:
- [Geo-distance query](https://www.elastic.co/docs/reference/query-languages/query-dsl/query-dsl-geo-distance-query)
- [Semantic filtering](https://www.elastic.co/docs/reference/elasticsearch/mapping-reference/semantic-text-reference)
- [Additive mappings](https://www.elastic.co/docs/api/doc/elasticsearch/operation/operation-indices-put-mapping)
- [Semantic ingestion and updates](https://www.elastic.co/docs/reference/elasticsearch/mapping-reference/semantic-text-ingestions)
