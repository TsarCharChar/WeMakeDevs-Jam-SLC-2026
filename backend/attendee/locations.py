from contextlib import suppress
from datetime import datetime
from typing import Annotated, Literal

from elastic_transport import TransportError
from elasticsearch import ApiError, Elasticsearch, NotFoundError
from fastapi import APIRouter, Depends, Request, Response
from pydantic import BaseModel, Field

from backend.attendee.auth import Attendee, current_attendee, person_id
from backend.attendee.elastic import RETENTION, elastic_errors, get_client, run_search
from backend.attendee.models import StoredDate
from backend.geospatial import ConversationCheckIn, Identifier, build_presence
from backend.vector_store import StoreError, utcnow

router = APIRouter()
LOCATIONS = "attendee-locations"
# Enough results to cover a crowded area without an unbounded terms filter.
NEARBY_LIMIT = 200
# Four decimal places is about 11 meters, roughly what phone GPS can promise indoors.
COORDINATE_DECIMALS = 4
PLACE_FIELDS = ("venue_id", "room_id", "zone_id", "floor", "accuracy_m", "updated_at")


class LocationUpdate(ConversationCheckIn):
    venue_id: Identifier | None = None
    source: Literal["device"] = "device"
    show_handle: bool = Field(default=False, strict=True)


class LocationResult(BaseModel):
    updated_at: str
    expires_at: str
    show_handle: bool


class Place(BaseModel):
    lat: float | None = None
    lon: float | None = None
    accuracy_m: float | None = None
    venue_id: str | None = None
    room_id: str | None = None
    zone_id: str | None = None
    floor: str | None = None
    updated_at: StoredDate = None


def location_id(attendee: Attendee) -> str:
    return person_id(attendee.conference, attendee.handle)


@router.put("/me/location", response_model=LocationResult)
def put_location(
    attendee: Annotated[Attendee, Depends(current_attendee)],
    body: LocationUpdate,
    request: Request,
    response: Response,
):
    response.headers["Cache-Control"] = "no-store"
    now = utcnow()
    presence = build_presence(body, conversation_expires_at=now + RETENTION, now=now)
    show_handle = presence.pop("show_handle")
    es = get_client(request)
    with elastic_errors():
        # Indexing into a missing index would auto-create it with the wrong mapping.
        if not es.indices.exists(index=LOCATIONS):
            raise StoreError(503, "Location sharing is not provisioned")
        # One document per attendee is replaced each time, so no movement history is kept.
        es.index(
            index=LOCATIONS,
            id=location_id(attendee),
            document={
                "conference": attendee.conference,
                "handle": attendee.handle,
                "show_handle": show_handle,
                "presence": presence,
            },
        )
    return {
        "updated_at": presence["updated_at"],
        "expires_at": presence["expires_at"],
        "show_handle": show_handle,
    }


@router.delete("/me/location", status_code=204)
def delete_location(attendee: Annotated[Attendee, Depends(current_attendee)], request: Request) -> None:
    es = get_client(request)
    with elastic_errors(), suppress(NotFoundError):
        es.delete(index=LOCATIONS, id=location_id(attendee), refresh="wait_for")


def nearby_handles(es: Elasticsearch, attendee: Attendee, filters: list[dict]) -> list[str]:
    data = run_search(
        es,
        index=LOCATIONS,
        size=NEARBY_LIMIT,
        source=["handle"],
        track_total_hits=False,
        query={
            "bool": {
                "filter": [{"term": {"conference": attendee.conference}}, *filters],
                "must_not": [{"term": {"handle": attendee.handle}}],
            }
        },
    )
    return [hit["_source"]["handle"] for hit in data.get("hits", {}).get("hits", [])]


def is_active(source: dict) -> bool:
    presence = source.get("presence") or {}
    try:
        expired = datetime.fromisoformat(presence["expires_at"]) <= utcnow()
    except (KeyError, TypeError, ValueError):
        return False
    return presence.get("shared") is True and not expired


def current_locations(es: Elasticsearch, conference: str, handles: set[str]) -> dict[str, dict]:
    if not handles:
        return {}
    ids = {person_id(conference, handle): handle for handle in handles}
    try:
        docs = es.mget(index=LOCATIONS, ids=list(ids)).get("docs", [])
    except (ApiError, TransportError):
        # A location outage should not hide the conversations themselves.
        return {}
    return {
        ids[doc["_id"]]: doc["_source"]
        for doc in docs
        if doc.get("found") and is_active(doc["_source"])
    }


def to_place(source: dict) -> dict:
    presence = source["presence"]
    location = presence.get("location") or {}
    return {
        **{field: presence.get(field) for field in PLACE_FIELDS},
        "lat": round(location["lat"], COORDINATE_DECIMALS) if location else None,
        "lon": round(location["lon"], COORDINATE_DECIMALS) if location else None,
    }


def purge_expired(es: Elasticsearch) -> None:
    # Expiry alone only hides a location, and last-known positions should not linger.
    es.delete_by_query(
        index=LOCATIONS,
        query={"range": {"presence.expires_at": {"lte": "now"}}},
        conflicts="proceed",
        ignore_unavailable=True,
        max_docs=1000,
    )
