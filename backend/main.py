
import os

from fastapi import FastAPI, HTTPException, Query
from elasticsearch import ApiError
from elastic_transport import TransportError

from backend.elastic_client import get_elasticsearch_client


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
    )
):
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
                        }
                    ]
                }
            },
            size=5
        )

        conversations = []

        for hit in response["hits"]["hits"]:
            source = hit["_source"]

            conversations.append({
                "id": hit["_id"],
                "conference": source.get("conference"),
                "transcript": source.get("transcript")
            })

        return {
            "conversations": conversations
        }

    except (ApiError, TransportError):
        raise HTTPException(
            status_code=503,
            detail="Elasticsearch search is unavailable"
        )
