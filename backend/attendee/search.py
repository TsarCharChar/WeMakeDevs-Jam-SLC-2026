from typing import Annotated

from elasticsearch import ApiError, Elasticsearch
from fastapi import APIRouter, Depends, Query, Request
from opentelemetry import trace
from pydantic import StringConstraints

from backend.attendee.auth import Attendee, current_attendee, require_conference
from backend.attendee.elastic import SHARED_CONTENT, checked_search, elastic_errors, get_client, visible_in
from backend.attendee.models import ContentSearchResponse
from backend.models import Identifier

router = APIRouter()

# The attendee handle is left out on purpose.
RESULT_FIELDS = ["title", "abstract", "speakers", "room", "start", "end", "gist", "source", "at", "topics"]


def hide_query_from_trace(request: Request):
    # Typed search terms are in the URL, which the server span would keep even on rejected requests.
    span = trace.get_current_span()
    attributes = getattr(span, "attributes", None) or {}
    clean = {
        "http.url": str(request.url.replace(query="")),
        "http.target": request.url.path,
        "url.query": "",
    }
    for key, value in clean.items():
        if key in attributes:
            span.set_attribute(key, value)


def build_query(term: str, conference: str, semantic: bool) -> dict:
    should = [
        {"multi_match": {"query": term, "fields": ["title^3", "abstract"]}},
        {"term": {"topics": {"value": term, "case_insensitive": True, "boost": 2.0}}},
        {"term": {"speakers": {"value": term, "case_insensitive": True}}},
    ]
    if semantic:
        # A match on semantic_text embeds the term with the endpoint pinned in the mapping.
        should += [{"match": {"content": {"query": term}}}, {"match": {"gist": {"query": term}}}]
    return {"bool": {"filter": visible_in(conference), "should": should, "minimum_should_match": 1}}


def as_list(value) -> list:
    # Elasticsearch returns a keyword field in whichever shape it was indexed.
    if value is None:
        return []
    return value if isinstance(value, list) else [value]


def to_result(hit: dict) -> dict:
    source = hit["_source"]
    return {
        **source,
        "topics": as_list(source.get("topics")),
        "speakers": as_list(source.get("speakers")) if "speakers" in source else None,
        "type": "talk" if hit["_index"].startswith("talks") else "moment",
        "id": hit["_id"],
        "score": hit["_score"],
    }


@router.get(
    "/search",
    dependencies=[Depends(hide_query_from_trace)],
    response_model=ContentSearchResponse,
    response_model_exclude_none=True,
)
def search_content(
    attendee: Annotated[Attendee, Depends(current_attendee)],
    q: Annotated[str, StringConstraints(strip_whitespace=True, min_length=1, max_length=200), Query()],
    conference: Identifier,
    es: Annotated[Elasticsearch, Depends(get_client)],
    limit: Annotated[int, Query(ge=1, le=50)] = 10,
):
    require_conference(attendee, conference)
    search = {"index": SHARED_CONTENT, "size": limit, "source": RESULT_FIELDS, "track_total_hits": False}
    mode = "hybrid"
    with elastic_errors():
        try:
            data = checked_search(es, query=build_query(q, conference, semantic=True), **search)
        except ApiError:
            # An embedding outage should only cost semantic ranking, not search.
            mode = "keyword"
            data = checked_search(es, query=build_query(q, conference, semantic=False), **search)
    results = [to_result(hit) for hit in data.get("hits", {}).get("hits", [])]
    return {"query": q, "conference": conference, "mode": mode, "results": results}
