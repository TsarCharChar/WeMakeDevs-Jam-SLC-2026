
import os

from fastapi import FastAPI, HTTPException, Query
from elasticsearch import ApiError
from elastic_transport import TransportError
from pydantic import ValidationError

from backend.elastic_client import get_elasticsearch_client
from backend.geospatial import GeographicSearch


app = FastAPI(
    title="ConFellow API",
    description="Backend API for the ConFellow conference companion",
    version="1.0.0"
)


# ------------------------------------
# Home endpoint
# ------------------------------------

@app.get("/")
def home():
    return {
        "message": "ConFellow backend is running"
    }


# ------------------------------------
# Kubernetes health check
# ------------------------------------

@app.get("/healthz")
def health():
    return {
        "status": "healthy"
    }


# ------------------------------------
# Kubernetes readiness check
# ------------------------------------

@app.get("/readyz")
def readiness():
    return {
        "status": "ready"
    }


# ------------------------------------
# Search conference conversations
# ------------------------------------

@app.get("/querysession")
def query_session(
    topic: str = Query(
        ...,
        min_length=2,
        max_length=120,
        description="Topic to search in conversation transcripts"
    ),
    conference: str | None = Query(default=None, min_length=1, max_length=128),
    venue_id: str | None = Query(default=None, min_length=1, max_length=128),
    room_id: str | None = Query(default=None, min_length=1, max_length=128),
    zone_id: str | None = Query(default=None, min_length=1, max_length=128),
    floor: str | None = Query(default=None, min_length=1, max_length=128),
    lat: float | None = Query(default=None, ge=-90, le=90, allow_inf_nan=False),
    lon: float | None = Query(default=None, ge=-180, le=180, allow_inf_nan=False),
    radius_m: float | None = Query(default=None, gt=0, le=10000, allow_inf_nan=False),
):
    try:
        geographic = GeographicSearch(
            conference=conference, venue_id=venue_id, room_id=room_id,
            zone_id=zone_id, floor=floor, lat=lat, lon=lon, radius_m=radius_m,
        )
    except ValidationError as exc:
        raise HTTPException(status_code=422, detail=exc.errors(include_context=False)) from exc

    # Create the Elasticsearch client
    es = get_elasticsearch_client()

    if es is None:
        raise HTTPException(
            status_code=503,
            detail="Elasticsearch is not configured"
        )

    # For now, search only the synthetic test document.
    # Real attendee conversations will require authentication
    # and per-user access controls.
    test_document_id = os.getenv(
        "ELASTICSEARCH_TEST_DOCUMENT_ID",
        "setup-smoke-20261109"
    )

    try:
        response = es.search(
            index="conversations",
            query={
                "bool": {
                    "must": [
                        {
                            "match": {
                                "transcript": topic
                            }
                        }
                    ],
                    "filter": [
                        {
                            "term": {
                                "consent": True
                            }
                        },
                        {
                            "ids": {
                                "values": [test_document_id]
                            }
                        },
                        *geographic.filters(),
                    ]
                }
            },
            size=5,
            source_includes=["conference", "transcript"] + (
                ["presence"] if geographic.enabled else []
            ),
        )

        conversations = []

        for hit in response["hits"]["hits"]:
            source = hit["_source"]

            conversation = {
                "id": hit["_id"],
                "conference": source.get("conference"),
                "transcript": source.get("transcript")
            }
            if geographic.enabled:
                conversation["presence"] = source.get("presence")
            conversations.append(conversation)

        return {
            "conversations": conversations
        }

    except (ApiError, TransportError):
        raise HTTPException(
            status_code=503,
            detail="Elasticsearch search is unavailable"
        )
