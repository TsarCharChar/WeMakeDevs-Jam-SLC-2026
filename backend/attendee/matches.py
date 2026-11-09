from typing import Annotated

from elasticsearch import Elasticsearch
from fastapi import APIRouter, Depends, Request, Response
from pydantic import BaseModel, Field

from backend.attendee.auth import Attendee, current_attendee, person_id, require_conference
from backend.attendee.elastic import get_client, get_person, run_search
from backend.attendee.locations import Place, current_locations, nearby_handles, to_place
from backend.attendee.models import StoredDate
from backend.attendee.search import as_list
from backend.attendee.transcripts import INDEX
from backend.geospatial import GeographicSearch
from backend.models import Identifier
from backend.vector_store import StoreError

router = APIRouter()
EXCERPT_LENGTH = 500


class MatchRequest(GeographicSearch):
    conference: Identifier
    interests: str | None = Field(default=None, min_length=1, max_length=500)
    limit: int = Field(default=10, ge=1, le=20, strict=True)
    min_score: float = Field(default=0, ge=0, le=1, allow_inf_nan=False)
    # A floor on the radius stops repeated shrinking searches from pinpointing someone.
    radius_m: float | None = Field(default=None, ge=50, le=10000)


class Match(BaseModel):
    id: str
    excerpt: str
    topics: list[str]
    updated_at: StoredDate
    score: float
    similarity: float
    place: Place | None = None
    handle: str | None = None


class MatchResults(BaseModel):
    matches: list[Match]


def saved_interests(es: Elasticsearch, attendee: Attendee) -> str:
    person = get_person(es, person_id(attendee.conference, attendee.handle))
    interests = person["_source"].get("interests") if person else None
    if not isinstance(interests, str) or not interests.strip():
        raise StoreError(422, "Add interests to your profile or send them with this search")
    return interests


def to_match(hit: dict, locations: dict[str, dict]) -> dict:
    source = hit["_source"]
    match = {
        "id": hit["_id"],
        "excerpt": source.get("transcript", "")[:EXCERPT_LENGTH],
        "topics": as_list(source.get("topics")),
        "updated_at": source.get("updated_at"),
        "score": hit["_score"],
        # Elasticsearch reports cosine vector scores as (1 + cosine) / 2.
        "similarity": max(-1.0, min(1.0, 2 * hit["_score"] - 1)),
    }
    location = locations.get(source.get("handle"))
    if location:
        match["place"] = to_place(location)
        # The author is named only when they chose to be findable by handle.
        if location.get("show_handle") is True:
            match["handle"] = source["handle"]
    return match


@router.post("/matches", response_model=MatchResults, response_model_exclude_none=True)
def find_matches(
    attendee: Annotated[Attendee, Depends(current_attendee)],
    body: MatchRequest,
    request: Request,
    response: Response,
):
    response.headers["Cache-Control"] = "no-store"
    require_conference(attendee, body.conference)
    es = get_client(request)
    interests = body.interests or saved_interests(es, attendee)
    place_filters = []
    if body.enabled:
        handles = nearby_handles(es, attendee, body.filters(include_scope=False))
        if not handles:
            return {"matches": []}
        place_filters = [{"terms": {"handle": handles}}]
    data = run_search(
        es,
        index=INDEX,
        size=body.limit,
        min_score=body.min_score,
        # The handle is read to find the author's location and is only returned if they allow it.
        source=["transcript", "topics", "updated_at", "handle"],
        track_total_hits=False,
        query={
            "bool": {
                # A match on semantic_text embeds the interests and compares them with the stored vectors.
                "must": [{"match": {"transcript": {"query": interests}}}],
                "filter": [
                    {"term": {"conference": attendee.conference}},
                    {"term": {"visibility": "conference"}},
                    {"term": {"consent": True}},
                    {"term": {"is_final": True}},
                    {"range": {"expires_at": {"gt": "now"}}},
                    *place_filters,
                ],
                "must_not": [{"term": {"handle": attendee.handle}}],
            }
        },
    )
    hits = data.get("hits", {}).get("hits", [])
    authors = {hit["_source"]["handle"] for hit in hits if hit["_source"].get("handle")}
    locations = current_locations(es, attendee.conference, authors)
    return {"matches": [to_match(hit, locations) for hit in hits]}
