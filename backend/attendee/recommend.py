"""Talks and moments ranked by what the attendee has said, typed and picked."""

from typing import Annotated, Literal

from elasticsearch import ApiError
from fastapi import APIRouter, Depends, Query, Request, Response
from pydantic import BaseModel

from backend.attendee.auth import Attendee, current_attendee, person_id, require_conference
from backend.attendee.elastic import (
    SHARED_CONTENT,
    checked_search,
    elastic_errors,
    get_client,
    get_person,
    visible_in,
)
from backend.attendee.models import SearchHit
from backend.attendee.search import RESULT_FIELDS, as_list, to_result
from backend.models import Identifier

router = APIRouter()

NOTES = "conversations"
MAX_NOTES = 5
# One embedding request covers the whole text, so it stays well inside the model's input size.
MAX_TEXT = 2000
MAX_KEYWORD_TEXT = 300


class BasedOn(BaseModel):
    notes: int
    topics: list[str]
    interests: bool


class RecommendationResponse(BaseModel):
    conference: str
    mode: Literal["hybrid", "keyword"]
    based_on: BasedOn
    results: list[SearchHit]


def stored_text(value) -> str:
    # Older semantic_text mappings return {"text": ...} in _source; newer ones return the string.
    if isinstance(value, dict):
        value = value.get("text")
    return value.strip() if isinstance(value, str) else ""


def recent_notes(es, attendee: Attendee) -> list[str]:
    # The handle only ever comes from the token, so a caller can read nobody else's notes.
    data = checked_search(
        es,
        index=NOTES,
        size=MAX_NOTES,
        source=["transcript"],
        sort=[{"updated_at": {"order": "desc", "unmapped_type": "date"}}],
        track_total_hits=False,
        query={
            "bool": {
                "filter": [
                    *visible_in(attendee.conference),
                    {"term": {"handle": attendee.handle}},
                    {"term": {"is_final": True}},
                ]
            }
        },
    )
    texts = (stored_text(hit.get("_source", {}).get("transcript")) for hit in data.get("hits", {}).get("hits", []))
    return [text for text in texts if text]


def build_query(attendee: Attendee, text: str, topics: list[str], semantic: bool) -> dict:
    should = [{"term": {"topics": {"value": topic, "case_insensitive": True, "boost": 2.0}}} for topic in topics]
    if text:
        should.append({"multi_match": {"query": text[:MAX_KEYWORD_TEXT], "fields": ["title^3", "abstract"]}})
    if text and semantic:
        # A match on semantic_text embeds the text with the endpoint pinned in the mapping.
        should += [{"match": {"content": {"query": text}}}, {"match": {"gist": {"query": text}}}]
    return {
        "bool": {
            "filter": visible_in(attendee.conference),
            # Talks have no handle, so this only removes the attendee's own shared moments.
            "must_not": [{"term": {"handle": attendee.handle}}],
            "should": should,
            "minimum_should_match": 1,
        }
    }


@router.get("/recommendations", response_model=RecommendationResponse, response_model_exclude_none=True)
def recommend(
    attendee: Annotated[Attendee, Depends(current_attendee)],
    request: Request,
    response: Response,
    conference: Identifier | None = None,
    limit: Annotated[int, Query(ge=1, le=50)] = 10,
):
    if conference is not None:
        require_conference(attendee, conference)
    # The ranking is personal, so shared caches must not keep it.
    response.headers["Cache-Control"] = "no-store"
    es = get_client(request)
    person = get_person(es, person_id(attendee.conference, attendee.handle))
    profile = person["_source"] if person else {}
    topics = [topic for topic in as_list(profile.get("topics")) if isinstance(topic, str)]
    interests = stored_text(profile.get("interests"))
    search = {"index": SHARED_CONTENT, "size": limit, "source": RESULT_FIELDS, "track_total_hits": False}
    with elastic_errors():
        notes = recent_notes(es, attendee)
        # Notes come first so a long interests field cannot push them out of the embedded text.
        text = " ".join([*notes, interests]).strip()[:MAX_TEXT]
        result = {
            "conference": attendee.conference,
            "mode": "hybrid" if text else "keyword",
            # Counts and the attendee's own topics only: the note text is never echoed back.
            "based_on": {"notes": len(notes), "topics": topics, "interests": bool(interests)},
            "results": [],
        }
        if not text and not topics:
            return result
        try:
            data = checked_search(es, query=build_query(attendee, text, topics, semantic=bool(text)), **search)
        except ApiError:
            if not text:
                raise
            # An embedding outage should only cost semantic ranking, not recommendations.
            result["mode"] = "keyword"
            data = checked_search(es, query=build_query(attendee, text, topics, semantic=False), **search)
    result["results"] = [to_result(hit) for hit in data.get("hits", {}).get("hits", [])]
    return result
