"""The topics an attendee is closest to, from what they have said, typed and picked."""

from typing import Annotated, Literal

from elasticsearch import ApiError
from fastapi import APIRouter, Depends, Query, Request, Response
from pydantic import BaseModel

from backend.attendee.auth import Attendee, current_attendee, person_id, require_conference
from backend.attendee.elastic import (
    PEOPLE,
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
# Topics are read off the best-matching talks and moments, so the pool is wider than the page.
TOPIC_POOL = 40
MAX_TOPICS = 12
PEOPLE_TOPIC_BUCKETS = 500


class BasedOn(BaseModel):
    notes: int
    topics: list[str]
    interests: bool


class TopicMatch(BaseModel):
    id: str
    label: str
    talks: int
    moments: int
    people: int
    mine: bool


class RecommendationResponse(BaseModel):
    conference: str
    mode: Literal["hybrid", "keyword"]
    based_on: BasedOn
    topics: list[TopicMatch]
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


def rank_topics(hits: list[dict], own: list[str]) -> list[dict]:
    # A topic is close when the talks and moments nearest the attendee carry it. Summing their
    # scores orders the topics; the sum itself is not returned, because it is not a percentage.
    mine = {topic.casefold() for topic in own}
    found: dict[str, dict] = {}
    for hit in hits:
        kind = "talks" if hit["_index"].startswith("talks") else "moments"
        for label in dict.fromkeys(topic for topic in as_list(hit["_source"].get("topics")) if isinstance(topic, str)):
            entry = found.setdefault(
                label.casefold(),
                {"id": label, "label": label, "talks": 0, "moments": 0, "people": 0, "weight": 0.0},
            )
            entry[kind] += 1
            entry["weight"] += hit.get("_score") or 0.0
    ranked = sorted(found.values(), key=lambda entry: entry["weight"], reverse=True)[:MAX_TOPICS]
    return [{**entry, "mine": entry["label"].casefold() in mine} for entry in ranked]


def count_people(es, attendee: Attendee, topics: list[dict]) -> None:
    # How many other attendees picked each topic. Buckets carry counts only: no handle is read.
    data = checked_search(
        es,
        index=PEOPLE,
        size=0,
        track_total_hits=False,
        query={
            "bool": {
                "filter": visible_in(attendee.conference),
                "must_not": [{"term": {"handle": attendee.handle}}],
            }
        },
        aggs={"topics": {"terms": {"field": "topics", "size": PEOPLE_TOPIC_BUCKETS}}},
    )
    counts: dict[str, int] = {}
    for bucket in data.get("aggregations", {}).get("topics", {}).get("buckets", []):
        key = str(bucket.get("key", "")).casefold()
        counts[key] = counts.get(key, 0) + int(bucket.get("doc_count", 0))
    for topic in topics:
        topic["people"] = counts.get(topic["label"].casefold(), 0)


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
    own_topics = [topic for topic in as_list(profile.get("topics")) if isinstance(topic, str)]
    interests = stored_text(profile.get("interests"))
    search = {"index": SHARED_CONTENT, "size": max(limit, TOPIC_POOL), "source": RESULT_FIELDS, "track_total_hits": False}
    with elastic_errors():
        notes = recent_notes(es, attendee)
        # Notes come first so a long interests field cannot push them out of the embedded text.
        text = " ".join([*notes, interests]).strip()[:MAX_TEXT]
        result = {
            "conference": attendee.conference,
            "mode": "hybrid" if text else "keyword",
            # Counts and the attendee's own topics only: the note text is never echoed back.
            "based_on": {"notes": len(notes), "topics": own_topics, "interests": bool(interests)},
            "topics": [],
            "results": [],
        }
        if not text and not own_topics:
            return result
        try:
            data = checked_search(es, query=build_query(attendee, text, own_topics, semantic=bool(text)), **search)
        except ApiError:
            if not text:
                raise
            # An embedding outage should only cost semantic ranking, not recommendations.
            result["mode"] = "keyword"
            data = checked_search(es, query=build_query(attendee, text, own_topics, semantic=False), **search)
        hits = data.get("hits", {}).get("hits", [])
        topics = rank_topics(hits, own_topics)
        if topics:
            count_people(es, attendee, topics)
    result["topics"] = [{key: value for key, value in topic.items() if key != "weight"} for topic in topics]
    result["results"] = [to_result(hit) for hit in hits[:limit]]
    return result
