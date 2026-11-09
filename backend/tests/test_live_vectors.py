"""Opt-in test against a provisioned real index; only writes synthetic scoped data."""

import os
from datetime import UTC, datetime, timedelta
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient

from backend.config import Settings
from backend.main import create_app


@pytest.mark.skipif(os.getenv("RUN_ELASTIC_INTEGRATION") != "1", reason="Live Elasticsearch test is opt-in")
def test_live_vector_roundtrip():
    settings = Settings.from_env()
    settings.validate()
    conference = "smoke-" + uuid4().hex
    headers = {"Authorization": "Bearer " + settings.service_token}
    body = {
        "conference": conference,
        "owner_id": "synthetic",
        "revision": 1,
        "visibility": "conference",
        "finalized": False,
        "expires_at": (datetime.now(UTC) + timedelta(hours=1)).isoformat(),
    }
    samples = {
        "containers": "Kubernetes scales container workloads with horizontal pod autoscaling and CPU metrics.",
        "cooking": "We bake sourdough bread with flour, yeast, water, and a hot oven.",
        "private": "Container orchestration and Kubernetes scaling.",
    }
    attempted = []
    with TestClient(create_app(settings)) as client:
        try:
            assert client.get("/readyz").json().get("vector_search") == "ready"
            for name, text in samples.items():
                attempted.append(name)
                payload = body | {"transcript": text}
                if name == "private":
                    payload["visibility"] = "private"
                response = client.put(f"/conversations/{name}", json=payload, headers=headers)
                assert response.status_code == 200, response.text
            query = {
                "conference": conference,
                "interests": "automatically adding replicas to handle container load",
            }
            response = client.post("/search", json=query, headers=headers)
            assert response.status_code == 200, response.text
            hits = response.json()["conversations"]
            assert hits and hits[0]["conversation_id"] == "containers"
            assert all(hit["conversation_id"] != "private" for hit in hits)
            revised = body | {"revision": 2, "transcript": samples["containers"] + " We also discuss KEDA."}
            assert client.put("/conversations/containers", json=revised, headers=headers).status_code == 200
            stale = client.put(
                "/conversations/containers",
                json=body | {"transcript": samples["containers"]},
                headers=headers,
            )
            assert stale.status_code == 409
        finally:
            failures = []
            for name in attempted:
                response = client.delete(
                    f"/conversations/{name}",
                    params={"conference": conference, "owner_id": "synthetic"},
                    headers=headers,
                )
                if response.status_code not in (200, 404):
                    failures.append(name)
            assert not failures, f"Synthetic cleanup failed for {failures}; scope: {conference}"
        response = client.post(
            "/search", json={"conference": conference, "interests": "containers"}, headers=headers
        )
        assert response.status_code == 200
        assert response.json()["conversations"] == []
