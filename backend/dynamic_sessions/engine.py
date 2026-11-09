from datetime import datetime, timedelta

from elasticsearch import Elasticsearch
from opentelemetry import trace

from backend.attendee.elastic import run_search
from backend.dynamic_sessions.alerts import send_alerts
from backend.dynamic_sessions.config import DynamicSessionSettings
from backend.dynamic_sessions.rooms import (
    NO_SLOT,
    acquire_lock,
    busy_intervals,
    candidates,
    load_rooms,
    lock_id,
)
from backend.dynamic_sessions.store import (
    INDEX,
    PROPOSED,
    SCHEDULED,
    SESSION,
    create_record,
    delete_record,
    get_record,
    provisioned,
    stable_id,
    update_record,
)
from backend.dynamic_sessions.topics import (
    TopicActivity,
    eligible_attendees,
    evaluate_threshold,
    group_topics,
    recent_participation,
)
from backend.vector_store import StoreError, utcnow

tracer = trace.get_tracer("confellow.dynamic_sessions")
DESCRIPTION = "A spontaneous discussion organized around common attendee interests"
PROPOSAL_LIFETIME = timedelta(days=1)
MAX_VARIANTS = 50


def find_recent(
    es: Elasticsearch, conference: str, topic_key: str, now: datetime, settings: DynamicSessionSettings
) -> dict | None:
    cooldown_start = now - timedelta(minutes=settings.cooldown_minutes)
    data = run_search(
        es,
        index=INDEX,
        size=1,
        sort=[{"created_at": {"order": "desc"}}],
        query={"bool": {
            "filter": [
                {"term": {"record_type": SESSION}},
                {"term": {"conference": conference}},
                {"term": {"topic_key": topic_key}},
            ],
            "should": [
                {"range": {"created_at": {"gte": cooldown_start.isoformat()}}},
                {"range": {"end": {"gt": now.isoformat()}}},
            ],
            "minimum_should_match": 1,
        }},
    )
    hits = data.get("hits", {}).get("hits", [])
    return get_record(es, hits[0]["_id"]) if hits else None


def build_proposal(
    conference: str,
    activity: TopicActivity,
    percentage: float | None,
    now: datetime,
    settings: DynamicSessionSettings,
) -> tuple[str, dict]:
    # The cooldown bucket makes the ID identical for every run in that period.
    bucket = int(now.timestamp() // (settings.cooldown_minutes * 60))
    session_id = stable_id("ds", conference, activity.key, bucket)
    return session_id, {
        "record_type": SESSION,
        "id": session_id,
        "conference": conference,
        "title": f"{activity.label} Discussion",
        "description": DESCRIPTION,
        "topic": activity.label,
        "topic_key": activity.key,
        "topics": activity.variants[:MAX_VARIANTS],
        "attendee_count": len(activity.handles),
        "attendee_percentage": percentage,
        "duration_minutes": settings.duration_minutes,
        "status": PROPOSED,
        "alerts_sent": False,
        "created_at": now.isoformat(),
        "updated_at": now.isoformat(),
        "expires_at": (now + PROPOSAL_LIFETIME).isoformat(),
    }


def deliver_alerts(es: Elasticsearch, session_id: str, settings: DynamicSessionSettings, now: datetime) -> str:
    hit = get_record(es, session_id)
    if hit is None or hit["_source"].get("alerts_sent"):
        return "already_sent"
    try:
        sent = send_alerts(es, hit["_source"], settings, now)
        update_record(es, hit, {"alerts_sent": True, "updated_at": now.isoformat()})
    except StoreError:
        # The session is already confirmed, so a later run retries only the alerts.
        return "failed"
    return f"sent:{sent}"


def try_schedule(
    es: Elasticsearch,
    hit: dict,
    now: datetime,
    settings: DynamicSessionSettings,
    only_room: str | None = None,
    require_authorized: bool = True,
) -> dict:
    session = hit["_source"]
    conference, session_id = session["conference"], session["id"]
    rooms = load_rooms(es, conference)
    busy = busy_intervals(es, conference, rooms, now, settings)
    options, reason = candidates(
        rooms, busy, session["attendee_count"], now, settings, only_room, require_authorized
    )
    for room, start, end in options:
        lock = acquire_lock(es, conference, room, start, end, session_id, now)
        if lock is None:
            continue
        changes = {
            "status": SCHEDULED,
            "start": start.isoformat(),
            "end": end.isoformat(),
            "timezone": room.timezone,
            "room": room.name,
            "room_id": room.room_id,
            "capacity": room.capacity,
            "accessibility": room.accessibility,
            "demo": room.demo,
            "pending_reason": None,
            "updated_at": now.isoformat(),
            "expires_at": (end + timedelta(days=1)).isoformat(),
        }
        if update_record(es, hit, changes):
            alerts = deliver_alerts(es, session_id, settings, now)
            return {"decision": "scheduled", "session_id": session_id, "alerts": alerts}
        current = get_record(es, session_id)
        if current and current["_source"].get("status") == SCHEDULED:
            # Another run confirmed this session, and the lock now belongs to it.
            return {"decision": "already_scheduled", "session_id": session_id}
        if lock == "created":
            delete_record(es, lock_id(conference, room.room_id, start))
        return {"decision": "pending", "session_id": session_id, "reason": "concurrent_update"}
    reason = reason or NO_SLOT
    if session.get("pending_reason") != reason:
        update_record(es, hit, {"pending_reason": reason, "updated_at": now.isoformat()})
    return {"decision": "pending", "session_id": session_id, "reason": reason}


def process_topic(
    es: Elasticsearch,
    conference: str,
    activity: TopicActivity,
    percentage: float | None,
    now: datetime,
    settings: DynamicSessionSettings,
    allow_new: bool,
    dry_run: bool,
) -> dict:
    existing = find_recent(es, conference, activity.key, now, settings)
    if existing is None:
        if not allow_new:
            return {"decision": "deferred", "reason": "run_limit"}
        session_id, proposal = build_proposal(conference, activity, percentage, now, settings)
        if dry_run:
            return {"decision": "would_propose", "session_id": session_id}
        create_record(es, session_id, proposal)
        existing = get_record(es, session_id)
        if existing is None:
            return {"decision": "pending", "session_id": session_id, "reason": "not_visible_yet"}
    source = existing["_source"]
    if source["status"] == PROPOSED:
        return {"decision": "would_schedule", "session_id": source["id"]} if dry_run else try_schedule(
            es, existing, now, settings
        )
    if source["status"] == SCHEDULED and not source.get("alerts_sent") and not dry_run:
        return {
            "decision": "cooldown",
            "session_id": source["id"],
            "alerts": deliver_alerts(es, source["id"], settings, now),
        }
    return {"decision": "cooldown", "session_id": source["id"]}


def evaluate_conference(
    es: Elasticsearch,
    conference: str,
    pairs: list[tuple[str, str]],
    now: datetime,
    settings: DynamicSessionSettings,
    dry_run: bool,
) -> dict:
    attendees = eligible_attendees(es, conference, now)
    activities = group_topics(pairs)
    decisions = []
    new_sessions = 0
    for activity in activities:
        unique = len(activity.handles)
        trigger, percentage = evaluate_threshold(unique, attendees, settings)
        if trigger is None:
            continue
        outcome = process_topic(
            es, conference, activity, percentage, now, settings, new_sessions < settings.max_new_per_run, dry_run
        )
        if outcome["decision"] in ("scheduled", "pending", "would_propose"):
            new_sessions += 1
        decision = {
            "topic": activity.label,
            "topic_key": activity.key,
            "unique_attendees": unique,
            "attendee_percentage": percentage,
            "trigger": trigger,
            **outcome,
        }
        decisions.append(decision)
        # Events carry counts and topic labels only, never handles or note text.
        trace.get_current_span().add_event(
            "dynamic_session.decision",
            {key: value for key, value in decision.items() if value is not None},
        )
    return {
        "eligible_attendees": attendees,
        "denominator": "people_index" if attendees else "unavailable",
        "topics_seen": len(activities),
        "decisions": decisions,
    }


def run_evaluation(
    es: Elasticsearch,
    settings: DynamicSessionSettings,
    now: datetime | None = None,
    conference: str | None = None,
    dry_run: bool = False,
) -> dict:
    now = now or utcnow()
    with tracer.start_as_current_span("dynamic_sessions.run") as span:
        span.set_attribute("dynamic_sessions.dry_run", dry_run)
        if not provisioned(es):
            span.set_attribute("dynamic_sessions.status", "not_provisioned")
            return {"status": "not_provisioned", "run_at": now.isoformat(), "conferences": {}}
        participation, truncated = recent_participation(es, settings, now, conference)
        summary = {
            "status": "ok",
            "run_at": now.isoformat(),
            "window_minutes": settings.window_minutes,
            "dry_run": dry_run,
            "truncated": truncated,
            "conferences": {},
            "errors": [],
        }
        for name, pairs in sorted(participation.items()):
            # One conference failing should not stop the others from being evaluated.
            try:
                summary["conferences"][name] = evaluate_conference(es, name, pairs, now, settings, dry_run)
            except StoreError:
                summary["errors"].append(name)
        if summary["errors"]:
            summary["status"] = "partial"
        span.set_attribute("dynamic_sessions.status", summary["status"])
        span.set_attribute("dynamic_sessions.conferences", len(participation))
        return summary
