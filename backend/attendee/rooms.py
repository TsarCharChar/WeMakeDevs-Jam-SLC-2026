"""Text chat in a topic or talk room, so people who share a space can talk."""

import hashlib
import json
from datetime import timedelta
from typing import Annotated, Literal
from uuid import uuid4

from elastic_transport import TransportError
from elasticsearch import ApiError
from fastapi import APIRouter, Depends, Path, Query, Request, Response
from pydantic import AwareDatetime, BaseModel, Field

from backend.attendee.auth import Attendee, current_attendee, person_id, require_conference
from backend.attendee.elastic import PEOPLE, RETENTION, checked_search, elastic_errors, get_client, visible_in
from backend.attendee.models import StoredDate
from backend.models import Identifier, Input
from backend.vector_store import StoreError, utcnow

router = APIRouter()

MESSAGES = "messages"
# Every topic and talk gets one room: topic:<name> or talk:<id>.
Room = Annotated[str, Path(min_length=6, max_length=140, pattern=r"^(topic|talk):[^\x00-\x1f\x7f]{1,128}$")]


class MessageWrite(Input):
    conference: Identifier
    # One line, the length of a short remark. Longer text belongs in a note.
    text: str = Field(min_length=1, max_length=280, pattern=r"^[^\x00-\x1f\x7f]+$")


class MessageCreated(BaseModel):
    id: str
    room: str
    at: str


class RoomMessage(BaseModel):
    id: str
    text: str
    at: StoredDate
    author: str
    mine: bool


class RoomPage(BaseModel):
    room: str
    people: int
    messages: list[RoomMessage]


class BusyRoom(BaseModel):
    room: str
    kind: Literal["topic", "talk"]
    name: str
    people: int
    messages: int
    latest: StoredDate
    wants_session: bool


class BusyRooms(BaseModel):
    conference: str
    window_minutes: int
    session_threshold: int
    rooms: list[BusyRoom]


def room_key(room: str) -> str:
    # eBPF and ebpf are one topic, so they are one room.
    return room.strip().casefold()


MAX_NAME = 60


def display_names(es, conference: str, handles: set[str]) -> dict[str, str]:
    # The name a person gave their profile (PUT /me display_name). Names are a nicety: if they
    # cannot be read, the chat still works and everyone shows as a guest.
    ids = {person_id(conference, handle): handle for handle in handles if handle}
    if not ids:
        return {}
    try:
        data = es.mget(index=PEOPLE, ids=list(ids), source=["display_name"])
    except (ApiError, TransportError):
        return {}
    names = {}
    for doc in data.get("docs", []):
        name = (doc.get("_source") or {}).get("display_name") if doc.get("found") else None
        if isinstance(name, str) and name.strip() and doc.get("_id") in ids:
            names[ids[doc["_id"]]] = name.strip()[:MAX_NAME]
    return names


def author_label(conference: str, room: str, handle: str, names: dict[str, str]) -> str:
    # A person who gave their profile a name is shown by it: that is what the name is for.
    if handle in names:
        return names[handle]
    # Otherwise a label that is stable inside one room and different in every other, so it cannot
    # be followed from room to room. The handle is the profile key and is never returned.
    digest = hashlib.sha256(json.dumps([conference, room, handle]).encode()).hexdigest()
    return "guest-" + digest[:6]


@router.post("/rooms/{room}/messages", status_code=201, response_model=MessageCreated)
def post_message(
    attendee: Annotated[Attendee, Depends(current_attendee)],
    room: Room,
    body: MessageWrite,
    request: Request,
):
    require_conference(attendee, body.conference)
    key = room_key(room)
    now = utcnow()
    es = get_client(request)
    message_id = uuid4().hex
    with elastic_errors():
        # Indexing into a missing index would auto-create it with the wrong mapping.
        if not es.indices.exists(index=MESSAGES):
            raise StoreError(503, "Rooms are not provisioned")
        es.index(
            index=MESSAGES,
            id=message_id,
            op_type="create",
            # A chat line has to be readable at once. Waiting for the scheduled refresh took two
            # to five seconds per message on Serverless, so this asks for one now instead.
            refresh=True,
            document={
                "conference": attendee.conference,
                "room": key,
                "handle": attendee.handle,
                "text": body.text,
                "at": now.isoformat(),
                "expires_at": (now + RETENTION).isoformat(),
            },
        )
    return {"id": message_id, "room": key, "at": now.isoformat()}


@router.get("/rooms/{room}/messages", response_model=RoomPage)
def read_messages(
    attendee: Annotated[Attendee, Depends(current_attendee)],
    room: Room,
    conference: Identifier,
    request: Request,
    response: Response,
    limit: Annotated[int, Query(ge=1, le=100)] = 50,
    after: AwareDatetime | None = None,
):
    require_conference(attendee, conference)
    response.headers["Cache-Control"] = "no-store"
    key = room_key(room)
    search = {
        "index": MESSAGES,
        "size": limit,
        # The handle is read to label and mark messages, and is dropped before the response.
        "source": ["handle", "text", "at"],
        "sort": [{"at": {"order": "desc", "unmapped_type": "date"}}],
        "track_total_hits": False,
        "query": {"bool": {"filter": [*visible_in(attendee.conference), {"term": {"room": key}}]}},
        "aggs": {"people": {"cardinality": {"field": "handle"}}},
    }
    if after:
        # A post filter narrows the page being read without narrowing the people count.
        search["post_filter"] = {"range": {"at": {"gt": after.isoformat()}}}
    es = get_client(request)
    with elastic_errors():
        data = checked_search(es, **search)
    # The newest page is fetched, then shown oldest first, as a chat reads.
    hits = list(reversed(data.get("hits", {}).get("hits", [])))
    names = display_names(es, attendee.conference, {hit["_source"].get("handle", "") for hit in hits})
    people = data.get("aggregations", {}).get("people", {}).get("value", 0)
    return {
        "room": key,
        "people": int(people or 0),
        "messages": [
            {
                "id": hit["_id"],
                "text": hit["_source"].get("text", ""),
                "at": hit["_source"].get("at"),
                "author": author_label(attendee.conference, key, hit["_source"].get("handle", ""), names),
                "mine": hit["_source"].get("handle") == attendee.handle,
            }
            for hit in hits
        ],
    }


@router.get("/rooms", response_model=BusyRooms)
def busy_rooms(
    attendee: Annotated[Attendee, Depends(current_attendee)],
    conference: Identifier,
    request: Request,
    response: Response,
    window_minutes: Annotated[int, Query(ge=5, le=1440)] = 60,
    session_threshold: Annotated[int, Query(ge=2, le=10000)] = 30,
    limit: Annotated[int, Query(ge=1, le=50)] = 20,
):
    """Rooms people are talking in right now, busiest first.

    An organizer can watch this to see live demand: when enough different people are talking in a
    room, `wants_session` turns true, which is the cue to offer that topic a space and a host.
    Only counts are returned, so it is safe for any attendee to see which rooms are filling up.
    """
    require_conference(attendee, conference)
    response.headers["Cache-Control"] = "no-store"
    since = utcnow() - timedelta(minutes=window_minutes)
    with elastic_errors():
        data = checked_search(
            get_client(request),
            index=MESSAGES,
            size=0,
            track_total_hits=False,
            query={"bool": {"filter": [*visible_in(attendee.conference), {"range": {"at": {"gte": since.isoformat()}}}]}},
            aggs={
                "rooms": {
                    "terms": {"field": "room", "size": 200},
                    "aggs": {"people": {"cardinality": {"field": "handle"}}, "latest": {"max": {"field": "at"}}},
                }
            },
        )
    rooms = []
    for bucket in data.get("aggregations", {}).get("rooms", {}).get("buckets", []):
        kind, _, name = str(bucket.get("key", "")).partition(":")
        if kind not in ("topic", "talk") or not name:
            continue
        people = int(bucket.get("people", {}).get("value", 0) or 0)
        rooms.append(
            {
                "room": bucket["key"],
                "kind": kind,
                "name": name,
                "people": people,
                "messages": int(bucket.get("doc_count", 0)),
                "latest": bucket.get("latest", {}).get("value_as_string"),
                "wants_session": people >= session_threshold,
            }
        )
    rooms.sort(key=lambda room: (-room["people"], -room["messages"], room["room"]))
    return {
        "conference": attendee.conference,
        "window_minutes": window_minutes,
        "session_threshold": session_threshold,
        "rooms": rooms[:limit],
    }
