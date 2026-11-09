"""Existing public synthetic-session search API, retained for Flutter compatibility."""

import os

from elastic_transport import TransportError
from elasticsearch import ApiError
from fastapi import APIRouter, HTTPException, Query

from backend.elastic_client import get_elasticsearch_client

router = APIRouter()


@router.get("/querysession")
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
