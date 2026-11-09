from datetime import datetime, timedelta

from elasticsearch import Elasticsearch

from backend.attendee.elastic import ALERTS, MOMENTS, PEOPLE, elastic_errors, run_search
from backend.dynamic_sessions.config import DynamicSessionSettings
from backend.dynamic_sessions.rooms import parse_time
from backend.dynamic_sessions.store import stable_id
from backend.vector_store import StoreError

MAX_RECIPIENTS = 1000
ALREADY_EXISTS = 409


def recipients(es: Elasticsearch, session: dict, settings: DynamicSessionSettings, now: datetime) -> list[str]:
    conference = session["conference"]
    active = [{"term": {"conference": conference}}, {"range": {"expires_at": {"gt": now.isoformat()}}}]
    since = (parse_time(session["created_at"]) - timedelta(minutes=settings.window_minutes)).isoformat()
    moments = run_search(
        es,
        index=MOMENTS,
        size=0,
        query={"bool": {"filter": [
            *active,
            {"terms": {"topics": session["topics"]}},
            {"range": {"at": {"gte": since}}},
        ]}},
        aggregations={"authors": {"terms": {"field": "handle", "size": MAX_RECIPIENTS}}},
    )
    authors = [bucket["key"] for bucket in moments.get("aggregations", {}).get("authors", {}).get("buckets", [])]
    # Requiring a live profile limits alerts to attendees who opted in and have not expired.
    people = run_search(
        es,
        index=PEOPLE,
        size=MAX_RECIPIENTS,
        source=["handle"],
        query={"bool": {
            "filter": active,
            "should": [{"terms": {"topics": session["topics"]}}, {"terms": {"handle": authors}}],
            "minimum_should_match": 1,
        }},
    )
    return sorted({hit["_source"]["handle"] for hit in people.get("hits", {}).get("hits", [])})


def send_alerts(es: Elasticsearch, session: dict, settings: DynamicSessionSettings, now: datetime) -> int:
    handles = recipients(es, session, settings, now)
    if not handles:
        return 0
    start = parse_time(session["start"])
    why = f"{session['title']} starts at {start.strftime('%-I:%M %p')} in {session['room']}."
    operations = []
    for handle in handles:
        operations.append({"create": {
            "_index": ALERTS,
            "_id": stable_id("dynamic-alert", session["conference"], session["id"], handle),
        }})
        operations.append({
            "conference": session["conference"],
            "to_handle": handle,
            "kind": "dynamic_session",
            "room": session["room"],
            "why": why,
            "seen": False,
            "at": now.isoformat(),
            "expires_at": session["expires_at"],
        })
    with elastic_errors():
        result = es.bulk(operations=operations)
    failed = [
        item for item in result.get("items", [])
        if item.get("create", {}).get("status", 201) not in (200, 201, ALREADY_EXISTS)
    ]
    if failed:
        raise StoreError(503, "Some alerts could not be written")
    return len(handles)
