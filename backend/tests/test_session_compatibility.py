"""Keep the existing Flutter search contract while adding the vector API."""

from unittest.mock import Mock

from fastapi.testclient import TestClient

from backend.config import Settings
from backend.main import create_app


def test_public_session_search_preserves_response_and_synthetic_scope(monkeypatch):
    elastic = Mock()
    elastic.search.return_value = {"hits": {"hits": [{"_id": "synthetic", "_source": {
        "conference": "cnh", "transcript": "Kubernetes scaling"
    }}]}}
    monkeypatch.setattr("backend.session_search.get_elasticsearch_client", lambda: elastic)
    monkeypatch.setenv("ELASTICSEARCH_TEST_DOCUMENT_ID", "synthetic")
    with TestClient(create_app(Settings())) as client:
        response = client.get("/querysession", params={"topic": "Kubernetes"})
        assert response.status_code == 200
        assert response.json() == {"conversations": [
            {"id": "synthetic", "conference": "cnh", "transcript": "Kubernetes scaling"}
        ]}
        assert client.get("/querysession", params={"topic": "x"}).status_code == 422
    query = elastic.search.call_args.kwargs
    assert query["index"] == "conversations"
    assert {"term": {"consent": True}} in query["query"]["bool"]["filter"]
    assert {"ids": {"values": ["synthetic"]}} in query["query"]["bool"]["filter"]


def test_public_session_search_still_reports_missing_credentials(monkeypatch):
    monkeypatch.setattr("backend.session_search.get_elasticsearch_client", lambda: None)
    with TestClient(create_app(Settings())) as client:
        assert client.get("/querysession", params={"topic": "Kubernetes"}).status_code == 503
