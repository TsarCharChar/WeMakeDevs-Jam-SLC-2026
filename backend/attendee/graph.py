from typing import Annotated

from elasticsearch import Elasticsearch
from fastapi import APIRouter, Depends, Query

from backend.attendee.elastic import PUBLIC_CONTENT, get_client, run_search, visible_in
from backend.attendee.models import GraphResponse
from backend.models import Identifier

router = APIRouter()
RELATED_TOPICS = 10


@router.get("/graph", response_model=GraphResponse)
def get_graph(
    conference: Identifier,
    es: Annotated[Elasticsearch, Depends(get_client)],
    limit: Annotated[int, Query(ge=1, le=100)] = 50,
):
    # size=0 returns only topic counts, so no attendee field can reach the response.
    data = run_search(
        es,
        index=PUBLIC_CONTENT,
        size=0,
        query={"bool": {"filter": visible_in(conference)}},
        aggregations={
            "topics": {
                "terms": {"field": "topics", "size": limit},
                "aggregations": {"related": {"terms": {"field": "topics", "size": RELATED_TOPICS}}},
            }
        },
    )
    buckets = data.get("aggregations", {}).get("topics", {}).get("buckets", [])
    nodes = [{"id": bucket["key"], "label": bucket["key"], "count": bucket["doc_count"]} for bucket in buckets]
    known = {node["id"] for node in nodes}
    weights = {}
    for bucket in buckets:
        for related in bucket["related"]["buckets"]:
            if related["key"] != bucket["key"] and related["key"] in known:
                weights[tuple(sorted((bucket["key"], related["key"])))] = related["doc_count"]
    edges = [
        {"source": source, "target": target, "weight": weight}
        for (source, target), weight in sorted(weights.items(), key=lambda item: (-item[1], item[0]))
    ]
    return {"conference": conference, "nodes": nodes, "edges": edges}
