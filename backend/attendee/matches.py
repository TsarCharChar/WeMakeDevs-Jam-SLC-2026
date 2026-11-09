from typing import Annotated

from elasticsearch import Elasticsearch
from fastapi import APIRouter, Depends, Request, Response
from pydantic import BaseModel, Field

from backend.attendee.auth import Attendee, current_attendee, person_id, require_conference
from backend.attendee.elastic import get_client, get_person, run_search
from backend.attendee.models import StoredDate
from backend.attendee.search import as_list
from backend.attendee.transcripts import INDEX
from backend.models import Identifier, Input
from backend.vector_store import StoreError

router = APIRouter()
EXCERPT_LENGTH = 500


class MatchRequest(Input):
    conference: Identifier
    interests: str | None = Field(default=None, min_length=1, max_length=500)
    limit: int = Field(default=10, ge=1, le=20, strict=True)
    min_score: float = Field(default=0, ge=0, le=1, allow_inf_nan=False)


class Match(BaseModel):
    id: str
    excerpt: str
    topics: list[str]
    updated_at: StoredDate
    score: float
    similarity: float


class MatchResults(BaseModel):
    matches: list[Match]


def saved_interests(es: Elasticsearch, attendee: Attendee) -> str:
    person = get_person(es, person_id(attendee.conference, attendee.handle))
    interests = person["_source"].get("interests") if person else None
    if not isinstance(interests, str) or not interests.strip():
        raise StoreError(422, "Add interests to your profile or send them with this search")
    return interests


def to_match(hit: dict) -> dict:
    source = hit["_source"]
    return {
        "id": hit["_id"],
        "excerpt": source.get("transcript", "")[:EXCERPT_LENGTH],
        "topics": as_list(source.get("topics")),
        "updated_at": source.get("updated_at"),
        "score": hit["_score"],
        # Elasticsearch reports cosine vector scores as (1 + cosine) / 2.
        "similarity": max(-1.0, min(1.0, 2 * hit["_score"] - 1)),
    }


@router.post("/matches", response_model=MatchResults)
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
    data = run_search(
        es,
        index=INDEX,
        size=body.limit,
        min_score=body.min_score,
        # The author's handle is left out on purpose.
        source=["transcript", "topics", "updated_at"],
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
                ],
                "must_not": [{"term": {"handle": attendee.handle}}],
            }
        },
    )
    return {"matches": [to_match(hit) for hit in data.get("hits", {}).get("hits", [])]}
