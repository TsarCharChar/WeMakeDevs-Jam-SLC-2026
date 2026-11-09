from contextlib import contextmanager
from datetime import timedelta

from elastic_transport import TransportError
from elasticsearch import ApiError, Elasticsearch, NotFoundError
from fastapi import Request

from backend.elastic_client import get_elasticsearch_client
from backend.vector_store import StoreError

PEOPLE = "people"
MOMENTS = "moments"
ALERTS = "alerts"
PUBLIC_CONTENT = "talks,moments"
RETENTION = timedelta(days=7)


def get_client(request: Request) -> Elasticsearch:
    client = getattr(request.app.state, "attendee_elastic", None)
    if client is None:
        client = get_elasticsearch_client()
        if client is None:
            raise StoreError(503, "Elasticsearch is not configured")
        request.app.state.attendee_elastic = client
    return client


@contextmanager
def elastic_errors():
    try:
        yield
    except (ApiError, TransportError):
        # Elasticsearch errors can quote stored text, so the cause is dropped on purpose.
        raise StoreError(503, "Elasticsearch is unavailable; retry later") from None


def get_person(es: Elasticsearch, doc_id: str) -> dict | None:
    try:
        return es.get(index=PEOPLE, id=doc_id)
    except NotFoundError as error:
        # A missing index also raises 404, and only a missing document says found=false.
        if isinstance(error.body, dict) and error.body.get("found") is False:
            return None
        raise StoreError(503, "Attendee profiles are not provisioned") from None
    except (ApiError, TransportError):
        raise StoreError(503, "Elasticsearch is unavailable; retry later") from None


def visible_in(conference: str) -> list[dict]:
    return [
        {"term": {"conference": conference}},
        {
            "bool": {
                "should": [
                    {"range": {"expires_at": {"gt": "now"}}},
                    {"bool": {"must_not": {"exists": {"field": "expires_at"}}}},
                ],
                "minimum_should_match": 1,
            }
        },
    ]


def checked_search(es: Elasticsearch, **search):
    # Missing indices count as empty so a fresh conference does not return errors.
    data = es.search(ignore_unavailable=True, allow_partial_search_results=False, **search)
    if data.get("timed_out") or data.get("_shards", {}).get("failed", 0):
        raise StoreError(503, "Search did not complete; retry later")
    return data


def run_search(es: Elasticsearch, **search):
    with elastic_errors():
        return checked_search(es, **search)
