from collections.abc import Iterator
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from elasticsearch import Elasticsearch

from backend.attendee.elastic import run_search
from backend.dynamic_sessions.config import DynamicSessionSettings
from backend.dynamic_sessions.store import (
    INDEX,
    LOCK,
    ROOM,
    SCHEDULED,
    SESSION,
    create_record,
    get_record,
    stable_id,
)

MAX_ROOMS = 200
MAX_TALKS = 1000
NO_ROOM = "no_designated_room"
NO_CAPACITY = "insufficient_capacity"
NO_SLOT = "no_available_slot"


@dataclass(frozen=True)
class Room:
    room_id: str
    name: str
    capacity: int
    zone: ZoneInfo
    timezone: str
    windows: tuple[tuple[datetime, datetime], ...]
    auto_schedule_authorized: bool
    accessibility: str | None
    demo: bool


def parse_time(value, zone=UTC) -> datetime | None:
    if isinstance(value, bool) or value is None:
        return None
    if isinstance(value, int | float):
        return datetime.fromtimestamp(value / 1000, UTC)
    try:
        parsed = datetime.fromisoformat(value)
    except (TypeError, ValueError):
        return None
    return parsed if parsed.utcoffset() is not None else parsed.replace(tzinfo=zone)


def parse_room(source: dict) -> Room | None:
    try:
        zone = ZoneInfo(source["timezone"])
        capacity = source["capacity"]
        windows = []
        for window in source["available_windows"]:
            start, end = parse_time(window["start"], zone), parse_time(window["end"], zone)
            if start and end and start < end:
                windows.append((start, end))
        if source.get("designated") is not True or not isinstance(capacity, int) or capacity <= 0:
            return None
        return Room(
            room_id=source["room_id"],
            name=source["room"],
            capacity=capacity,
            zone=zone,
            timezone=source["timezone"],
            windows=tuple(windows),
            auto_schedule_authorized=source.get("auto_schedule_authorized") is True,
            accessibility=source.get("accessibility"),
            demo=source.get("demo") is True,
        )
    except (KeyError, TypeError, ValueError, ZoneInfoNotFoundError):
        return None


def load_rooms(es: Elasticsearch, conference: str) -> list[Room]:
    data = run_search(
        es,
        index=INDEX,
        size=MAX_ROOMS,
        query={"bool": {"filter": [{"term": {"record_type": ROOM}}, {"term": {"conference": conference}}]}},
    )
    rooms = (parse_room(hit["_source"]) for hit in data.get("hits", {}).get("hits", []))
    return [room for room in rooms if room is not None]


def slots(room: Room, now: datetime, settings: DynamicSessionSettings) -> Iterator[tuple[datetime, datetime]]:
    earliest = (now + timedelta(minutes=settings.lead_minutes)).astimezone(room.zone)
    extra = 1 if earliest.second or earliest.microsecond else 0
    minutes = earliest.hour * 60 + earliest.minute + extra
    # Starts sit on a shared grid so two runs always compete for the same lock.
    start = earliest.replace(second=0, microsecond=0) + timedelta(
        minutes=extra + (-minutes % settings.duration_minutes)
    )
    length = timedelta(minutes=settings.duration_minutes)
    last = now + timedelta(minutes=settings.horizon_minutes)
    while start <= last:
        end = start + length
        if any(window_start <= start and end <= window_end for window_start, window_end in room.windows):
            yield start, end
        start = end


def busy_intervals(
    es: Elasticsearch, conference: str, rooms: list[Room], now: datetime, settings: DynamicSessionSettings
) -> dict[str, list[tuple[datetime, datetime]]]:
    horizon = now + timedelta(minutes=settings.horizon_minutes + settings.lead_minutes + settings.duration_minutes)
    window = [
        {"term": {"conference": conference}},
        {"range": {"start": {"lt": horizon.isoformat()}}},
        {"range": {"end": {"gt": now.isoformat()}}},
    ]
    labels = {label: room.room_id for room in rooms for label in (room.room_id, room.name)}
    busy: dict[str, list[tuple[datetime, datetime]]] = {room.room_id: [] for room in rooms}

    def record(hit: dict, room_key: str):
        source = hit["_source"]
        room_id = labels.get(source.get(room_key))
        start, end = parse_time(source.get("start")), parse_time(source.get("end"))
        if room_id and start and end:
            busy[room_id].append((start, end))

    talks = run_search(
        es,
        index="talks",
        size=MAX_TALKS,
        source=["room", "start", "end"],
        query={"bool": {"filter": [*window, {"terms": {"room": sorted(labels)}}]}},
    )
    for hit in talks.get("hits", {}).get("hits", []):
        record(hit, "room")
    sessions = run_search(
        es,
        index=INDEX,
        size=MAX_TALKS,
        source=["room_id", "start", "end"],
        query={"bool": {"filter": [
            *window,
            {"term": {"record_type": SESSION}},
            {"term": {"status": SCHEDULED}},
        ]}},
    )
    for hit in sessions.get("hits", {}).get("hits", []):
        record(hit, "room_id")
    return busy


def candidates(
    rooms: list[Room],
    busy: dict[str, list[tuple[datetime, datetime]]],
    attendee_count: int,
    now: datetime,
    settings: DynamicSessionSettings,
    only_room: str | None = None,
    require_authorized: bool = True,
) -> tuple[list[tuple[Room, datetime, datetime]], str | None]:
    eligible = [
        room for room in rooms
        if (only_room is None or room.room_id == only_room)
        and (room.auto_schedule_authorized or not require_authorized)
    ]
    if not eligible:
        return [], NO_ROOM
    fitting = [room for room in eligible if room.capacity >= attendee_count]
    if not fitting:
        return [], NO_CAPACITY
    options = [
        (room, start, end)
        for room in fitting
        for start, end in slots(room, now, settings)
        if not any(start < taken_end and taken_start < end for taken_start, taken_end in busy.get(room.room_id, []))
    ]
    if not options:
        return [], NO_SLOT
    # Earliest first, then the smallest room that fits, so large rooms stay free.
    options.sort(key=lambda item: (item[1].astimezone(UTC), item[0].capacity, item[0].room_id))
    return options, None


def lock_id(conference: str, room_id: str, start: datetime) -> str:
    return stable_id("lock", conference, room_id, start.astimezone(UTC).isoformat())


def acquire_lock(
    es: Elasticsearch, conference: str, room: Room, start: datetime, end: datetime, session_id: str, now: datetime
) -> str | None:
    doc_id = lock_id(conference, room.room_id, start)
    created = create_record(es, doc_id, {
        "record_type": LOCK,
        "conference": conference,
        "room_id": room.room_id,
        "session_id": session_id,
        "start": start.isoformat(),
        "end": end.isoformat(),
        "created_at": now.isoformat(),
        "expires_at": (end + timedelta(days=1)).isoformat(),
    })
    if created:
        return "created"
    existing = get_record(es, doc_id)
    # A retry of the same session may find the lock it already holds.
    if existing and existing["_source"].get("session_id") == session_id:
        return "existing"
    return None
