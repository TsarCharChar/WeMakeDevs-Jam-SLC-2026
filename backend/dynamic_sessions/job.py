import argparse
import json
import sys
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

from elastic_transport import TransportError
from elasticsearch import ApiError, Elasticsearch

from backend.attendee.elastic import MOMENTS, elastic_errors
from backend.dynamic_sessions.config import DynamicSessionSettings
from backend.dynamic_sessions.engine import run_evaluation
from backend.dynamic_sessions.store import INDEX, ROOM, provisioned, stable_id
from backend.elastic_client import get_elasticsearch_client
from backend.vector_store import StoreError, utcnow

DEMO_ZONE = "America/Denver"
DEMO_ATTENDEES = 55
DEMO_TOPICS = ("Kubernetes Autoscaling", "kubernetes auto-scaling", "K8s autoscaling")
DEMO_ROOMS = (
    ("dynamic-room-a", "Dynamic Room A", 60, "Step-free access, hearing loop"),
    ("dynamic-room-b", "Dynamic Room B", 120, "Step-free access"),
)


def demo_room(conference: str, room_id: str, name: str, capacity: int, accessibility: str, now: datetime) -> dict:
    today = now.astimezone(ZoneInfo(DEMO_ZONE)).date()
    windows = [
        {"start": f"{today + timedelta(days=day)}T00:00:00", "end": f"{today + timedelta(days=day + 1)}T00:00:00"}
        for day in range(2)
    ]
    return {
        "record_type": ROOM,
        "conference": conference,
        "room_id": room_id,
        "room": name,
        "capacity": capacity,
        "designated": True,
        "auto_schedule_authorized": True,
        "timezone": DEMO_ZONE,
        "available_windows": windows,
        "accessibility": accessibility,
        "demo": True,
    }


def seed_demo(es: Elasticsearch, conference: str, now: datetime | None = None) -> dict:
    now = now or utcnow()
    operations = []
    for room_id, name, capacity, accessibility in DEMO_ROOMS:
        operations.append({"index": {"_index": INDEX, "_id": stable_id("room", conference, room_id)}})
        operations.append(demo_room(conference, room_id, name, capacity, accessibility, now))
    for number in range(DEMO_ATTENDEES):
        operations.append({"index": {"_index": MOMENTS, "_id": stable_id("demo-moment", conference, number)}})
        operations.append({
            "conference": conference,
            "handle": f"demo-attendee-{number:03d}",
            "source": "notes",
            "gist": "Synthetic demo note about tuning Kubernetes autoscaling.",
            "topics": [DEMO_TOPICS[number % len(DEMO_TOPICS)]],
            "at": now.isoformat(),
            "expires_at": (now + timedelta(hours=2)).isoformat(),
        })
    with elastic_errors():
        result = es.bulk(operations=operations, refresh="wait_for")
    if result.get("errors"):
        raise StoreError(503, "Some demo records could not be written")
    return {"status": "seeded", "conference": conference, "rooms": len(DEMO_ROOMS), "moments": DEMO_ATTENDEES}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Evaluate dynamic sessions or seed synthetic demo data")
    commands = parser.add_subparsers(dest="command", required=True)
    run = commands.add_parser("run", help="Run one evaluation")
    run.add_argument("--conference")
    run.add_argument("--dry-run", action="store_true")
    seed = commands.add_parser("seed-demo", help="Write clearly labeled synthetic rooms and notes")
    seed.add_argument("--conference", required=True)
    seed.add_argument("--allow-non-demo-conference", action="store_true")
    args = parser.parse_args(argv)

    es = get_elasticsearch_client()
    if es is None:
        print(json.dumps({"status": "error", "reason": "elasticsearch_not_configured"}))
        return 1
    try:
        if args.command == "seed-demo":
            if not (args.conference.startswith("demo") or args.allow_non_demo_conference):
                parser.error("Synthetic data needs a conference starting with demo, or --allow-non-demo-conference")
            if not provisioned(es):
                print(json.dumps({"status": "not_provisioned"}))
                return 1
            print(json.dumps(seed_demo(es, args.conference)))
            return 0
        summary = run_evaluation(
            es, DynamicSessionSettings.from_env(), conference=args.conference, dry_run=args.dry_run
        )
    except (StoreError, ValueError, ApiError, TransportError) as error:
        reason = error.message if isinstance(error, StoreError) else type(error).__name__
        print(json.dumps({"status": "error", "reason": reason}))
        return 1
    print(json.dumps(summary, sort_keys=True))
    # A partial run failed for at least one conference, so Kubernetes should show it.
    return 1 if summary["status"] == "partial" else 0


if __name__ == "__main__":
    sys.exit(main())
