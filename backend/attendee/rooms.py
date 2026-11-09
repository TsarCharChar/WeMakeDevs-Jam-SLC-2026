"""Text chat in a topic or talk room, so people who share a space can talk."""

import hashlib
import json
from typing import Annotated
from uuid import uuid4

from fastapi import APIRouter, Depends, Path, Query, Request, Response
from pydantic import AwareDatetime, BaseModel, Field

from backend.attendee.auth import Attendee, current_attendee, require_conference
from backend.attendee.elastic import RETENTION, checked_search, elastic_errors, get_client, visible_in
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


def room_key(room: str) -> str:
    # eBPF and ebpf are one topic, so they are one room.
    return room.strip().casefold()


GENERATED_HANDLE = "cf_"


def author_label(conference: str, room: str, handle: str) -> str:
    # A name the person chose for their profile is shown as it is: that is what they picked it for.
    if handle and not handle.startswith(GENERATED_HANDLE):
        return handle
    # A handle the app generated for the device is not a name. It becomes a label that is stable
    # inside one room and different in every other, so it cannot be followed from room to room.
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
    with elastic_errors():
        data = checked_search(get_client(request), **search)
    # The newest page is fetched, then shown oldest first, as a chat reads.
    hits = list(reversed(data.get("hits", {}).get("hits", [])))
    people = data.get("aggregations", {}).get("people", {}).get("value", 0)
    return {
        "room": key,
        "people": int(people or 0),
        "messages": [
            {
                "id": hit["_id"],
                "text": hit["_source"].get("text", ""),
                "at": hit["_source"].get("at"),
                "author": author_label(attendee.conference, key, hit["_source"].get("handle", "")),
                "mine": hit["_source"].get("handle") == attendee.handle,
            }
            for hit in hits
        ],
    }
