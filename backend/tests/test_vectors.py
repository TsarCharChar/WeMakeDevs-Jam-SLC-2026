"""API/ES wire contract tests. These do not claim to evaluate real embeddings."""

import asyncio
import copy
import json
from dataclasses import replace
from datetime import UTC, datetime, timedelta

import httpx
import pytest
from fastapi.testclient import TestClient

from backend.config import Settings
from backend.main import create_app
from backend.schema import conversation_mapping, validate_mapping
from backend.vector_store import VectorStore, document_id

NOW = datetime(2026, 11, 9, 12, tzinfo=UTC)
SETTINGS = Settings(
    elasticsearch_url="https://elastic.example",
    elasticsearch_api_key="test-key",
    inference_id="test-dense-endpoint",
    service_token="test-service-token-32-characters-long",
)
AUTH = {"Authorization": "Bearer " + SETTINGS.service_token}
BODY = {
    "conference": "cnh",
    "owner_id": "owner-1",
    "revision": 1,
    "transcript": "Scaling Kubernetes workloads",
    "expires_at": (NOW + timedelta(days=1)).isoformat(),
    "visibility": "conference",
    "finalized": False,
}


class ElasticDouble:
    """Models the create/CAS wire contract; all scoring is explicitly stubbed."""

    def __init__(self):
        self.documents = {}
        self.requests = []
        self.mapping = conversation_mapping(SETTINGS.inference_id)
        self.failure = None
        self.before_write = None
        self.search_override = None

    def __call__(self, request):
        self.requests.append(request)
        if self.failure:
            return httpx.Response(self.failure, json={"error": "secret transcript and API key"})
        path = request.url.path
        if path.endswith("/_mapping"):
            return httpx.Response(200, json={"conversations-v1": {"mappings": self.mapping}})
        if path.startswith("/_alias/"):
            return httpx.Response(
                200, json={"conversations-v1": {"aliases": {SETTINGS.index: {"is_write_index": True}}}}
            )
        if "/_doc/" in path:
            doc_id = path.rsplit("/", 1)[1]
            if request.method == "GET":
                doc = self.documents.get(doc_id)
                return httpx.Response(200 if doc else 404, json=copy.deepcopy(doc) if doc else {})
            assert request.url.params["require_alias"] == "true"
            if self.before_write:
                self.before_write(doc_id)
            current = self.documents.get(doc_id)
            params = request.url.params
            if params.get("op_type") == "create":
                if current:
                    return httpx.Response(409, json={})
            elif (
                not current
                or int(params["if_seq_no"]) != current["_seq_no"]
                or int(params["if_primary_term"]) != current["_primary_term"]
            ):
                return httpx.Response(409, json={})
            self.documents[doc_id] = {
                "_id": doc_id,
                "_source": json.loads(request.content),
                "_seq_no": current["_seq_no"] + 1 if current else 0,
                "_primary_term": 1,
            }
            return httpx.Response(200, json={"result": "updated"})
        if path.endswith("/_search"):
            if self.search_override is not None:
                return httpx.Response(200, json=self.search_override)
            body = json.loads(request.content)
            filters = body["query"]["bool"]["filter"]
            matches = []
            for doc in self.documents.values():
                source = doc["_source"]
                allowed = True
                for clause in filters:
                    if "term" in clause:
                        allowed &= all(source.get(k) == v for k, v in clause["term"].items())
                    if "range" in clause:
                        if "expires_at" not in source:
                            allowed = False
                        else:
                            expiry = datetime.fromisoformat(source["expires_at"])
                            allowed &= (
                                expiry > NOW if "gt" in clause["range"]["expires_at"] else expiry <= NOW
                            )
                if allowed:
                    matches.append(
                        {
                            **doc,
                            "_score": 0.9,
                            "_source": {key: source[key] for key in body["_source"] if key in source},
                        }
                    )
            return httpx.Response(
                200,
                json={
                    "timed_out": False,
                    "_shards": {"failed": 0},
                    "hits": {"hits": matches[: body["size"]]},
                },
            )
        raise AssertionError(f"Unexpected ES request: {request.method} {path}")


@pytest.fixture
def api():
    elastic = ElasticDouble()
    client = httpx.AsyncClient(base_url=SETTINGS.elasticsearch_url, transport=httpx.MockTransport(elastic))
    store = VectorStore(SETTINGS, client, clock=lambda: NOW)
    with TestClient(create_app(SETTINGS, store)) as app:
        yield app, elastic, store
    asyncio.run(client.aclose())


def put(api, **changes):
    return api[0].put("/conversations/conversation-1", json=BODY | changes, headers=AUTH)


def test_revision_replaces_full_transcript_without_duplicates(api):
    assert put(api).json()["result"] == "created"
    assert put(api, revision=2, transcript="Revised entire conversation").json()["result"] == "updated"
    assert len(api[1].documents) == 1
    stored = next(iter(api[1].documents.values()))["_source"]
    assert stored["transcript"] == "Revised entire conversation"
    assert stored["revision"] == 2


def test_identical_retry_does_not_reembed(api):
    put(api)
    before = len([r for r in api[1].requests if r.method == "PUT"])
    assert put(api).json()["result"] == "unchanged"
    assert len([r for r in api[1].requests if r.method == "PUT"]) == before


def test_same_revision_different_payload_and_stale_revisions_conflict(api):
    put(api, revision=2)
    assert put(api, revision=2, transcript="Changed").status_code == 409
    assert put(api).status_code == 409
    assert next(iter(api[1].documents.values()))["_source"]["revision"] == 2


def test_concurrent_newer_revision_wins(api):
    put(api)

    def race(doc_id):
        api[1].before_write = None
        current = api[1].documents[doc_id]
        current["_seq_no"] += 1
        current["_source"]["revision"] = 3
        current["_source"]["transcript"] = "Newest text"

    api[1].before_write = race
    assert put(api, revision=2).status_code == 409
    assert next(iter(api[1].documents.values()))["_source"]["transcript"] == "Newest text"


def test_concurrent_create_is_reread_and_deduplicated(api):
    def race(doc_id):
        api[1].before_write = None
        request = api[1].requests[-1]
        api[1].documents[doc_id] = {
            "_id": doc_id,
            "_seq_no": 0,
            "_primary_term": 1,
            "_source": json.loads(request.content),
        }

    api[1].before_write = race
    assert put(api).json()["result"] == "unchanged"
    assert len(api[1].documents) == 1


def test_conversation_identity_is_scoped(api):
    put(api)
    put(api, owner_id="owner-2")
    put(api, conference="another-conference")
    assert len(api[1].documents) == 3
    assert document_id("a", "b", "c") != document_id("ab", "", "c")


def test_finalized_transcript_is_sealed_but_retry_allowed(api):
    put(api, finalized=True)
    assert put(api, finalized=True).json()["result"] == "unchanged"
    assert put(api, revision=2, transcript="Changed").status_code == 409


def test_retention_cannot_be_extended(api):
    put(api)
    assert put(api, revision=2, expires_at=(NOW + timedelta(days=2)).isoformat()).status_code == 409


@pytest.mark.parametrize(
    "changes",
    [
        {"transcript": "   "},
        {"transcript": "x" * 20001},
        {"revision": 0},
        {"revision": True},
        {"revision": 9223372036854775808},
        {"expires_at": "2026-11-09T13:00:00"},
        {"expires_at": NOW.isoformat()},
        {"expires_at": (NOW + timedelta(days=8)).isoformat()},
        {"conference": "../other"},
        {"visibility": "public"},
        {"unknown": "value"},
    ],
)
def test_invalid_ingestion_is_rejected(api, changes):
    response = put(api, **changes)
    assert response.status_code == 422
    assert not api[1].documents


def test_private_expired_deleted_and_other_conferences_are_excluded(api):
    for name, changes in [
        ("visible", {}),
        ("private", {"visibility": "private"}),
        ("other", {"conference": "elsewhere"}),
        ("expired", {}),
        ("deleted", {}),
    ]:
        api[0].put(f"/conversations/{name}", json=BODY | changes, headers=AUTH)
    expired = api[1].documents[document_id("cnh", "owner-1", "expired")]["_source"]
    expired["expires_at"] = (NOW - timedelta(seconds=1)).isoformat()
    api[0].delete("/conversations/deleted?conference=cnh&owner_id=owner-1", headers=AUTH)
    response = api[0].post(
        "/search", json={"conference": "cnh", "interests": "container orchestration"}, headers=AUTH
    )
    assert response.status_code == 200
    assert [c["conversation_id"] for c in response.json()["conversations"]] == ["visible"]
    assert "owner_id" not in response.text
    query = json.loads(api[1].requests[-1].content)
    assert query["query"]["bool"]["must"] == [{"match": {"transcript": {"query": "container orchestration"}}}]
    assert api[1].requests[-1].url.params["allow_partial_search_results"] == "false"


def test_unpublished_is_private_by_default(api):
    body = dict(BODY)
    del body["visibility"]
    api[0].put("/conversations/private-default", json=body, headers=AUTH)
    assert next(iter(api[1].documents.values()))["_source"]["visibility"] == "private"


@pytest.mark.parametrize(
    "changes",
    [{"interests": " "}, {"interests": "x" * 501}, {"limit": 51}, {"min_score": -1}, {"conference": "*"}],
)
def test_invalid_search_is_rejected(api, changes):
    response = api[0].post("/search", json={"conference": "cnh", "interests": "AI"} | changes, headers=AUTH)
    assert response.status_code == 422


def test_delete_removes_vectors_and_prevents_resurrection(api):
    put(api)
    url = "/conversations/conversation-1?conference=cnh&owner_id=owner-1"
    assert api[0].delete(url, headers=AUTH).status_code == 200
    source = next(iter(api[1].documents.values()))["_source"]
    assert source["deleted"] is True
    assert "transcript" not in source and "payload_hash" not in source
    assert put(api, revision=100).status_code == 410
    assert api[0].delete(url, headers=AUTH).status_code == 200


def test_delete_wrong_owner_cannot_delete_original(api):
    put(api)
    assert (
        api[0].delete("/conversations/conversation-1?conference=cnh&owner_id=wrong", headers=AUTH).status_code
        == 404
    )
    assert not next(iter(api[1].documents.values()))["_source"]["deleted"]


def test_expiry_removes_only_expired_content(api):
    put(api)
    api[0].put("/conversations/expired", json=BODY, headers=AUTH)
    expired = api[1].documents[document_id("cnh", "owner-1", "expired")]
    expired["_source"]["expires_at"] = (NOW - timedelta(seconds=1)).isoformat()
    assert asyncio.run(api[2].expire()) == {"expired": 1, "scanned": 1}
    assert "transcript" not in api[1].documents[expired["_id"]]["_source"]
    assert "transcript" in api[1].documents[document_id("cnh", "owner-1", "conversation-1")]["_source"]


@pytest.mark.parametrize("status", [401, 403, 429, 500, 503, 302])
def test_upstream_errors_fail_closed_without_leaking_details(api, status):
    api[1].failure = status
    response = put(api)
    assert response.status_code == 503
    assert "secret transcript" not in response.text


def test_partial_search_is_not_reported_as_success(api):
    api[1].search_override = {"timed_out": True, "hits": {"hits": []}}
    assert (
        api[0].post("/search", json={"conference": "cnh", "interests": "AI"}, headers=AUTH).status_code == 503
    )


def test_unauthenticated_requests_never_reach_elastic(api):
    assert api[0].put("/conversations/c1", json=BODY).status_code == 401
    assert api[0].post("/search", json={"conference": "cnh", "interests": "AI"}).status_code == 401
    assert not api[1].requests


def test_unconfigured_service_preserves_preview_and_disables_vectors():
    with TestClient(create_app(Settings())) as client:
        assert client.get("/healthz").status_code == 200
        assert client.get("/readyz").json()["vector_search"] == "disabled"
        assert client.post("/search", json={"conference": "cnh", "interests": "AI"}).status_code == 503


def test_schema_mismatch_prevents_writes(api):
    api[1].mapping["properties"]["transcript"]["search_inference_id"] = "wrong-model"
    assert put(api).status_code == 503
    assert not api[1].documents


def test_schema_rejects_multiple_backing_indices():
    mapping = {"mappings": conversation_mapping("endpoint")}
    with pytest.raises(ValueError):
        validate_mapping({"one": mapping, "two": mapping}, "endpoint")


def test_configuration_requires_https_and_single_alias():
    SETTINGS.validate()
    for changes in [
        {"elasticsearch_url": "http://elastic.example"},
        {"index": "*"},
        {"elasticsearch_url": "https://user:password@elastic.example"},
    ]:
        with pytest.raises(ValueError):
            replace(SETTINGS, **changes).validate()


def test_partial_configuration_fails_readiness():
    with TestClient(create_app(Settings(inference_id="partially-configured"))) as client:
        assert client.get("/healthz").status_code == 200
        assert client.get("/readyz").status_code == 503


def test_existing_session_credentials_do_not_enable_vector_api():
    settings = Settings(elasticsearch_url="https://elastic.example", elasticsearch_api_key="test-key")
    with TestClient(create_app(settings)) as client:
        assert client.get("/readyz").json()["vector_search"] == "disabled"


def test_transport_timeout_returns_unavailable(api):
    def timeout(_request):
        raise httpx.ReadTimeout("sensitive connection details")

    api[2].client = httpx.AsyncClient(
        base_url=SETTINGS.elasticsearch_url, transport=httpx.MockTransport(timeout)
    )
    assert put(api).status_code == 503
    asyncio.run(api[2].client.aclose())


def test_concurrent_delete_wins_over_pending_update(api):
    put(api)

    def race(doc_id):
        api[1].before_write = None
        current = api[1].documents[doc_id]
        current["_seq_no"] += 1
        current["_source"] = api[2].tombstone(current["_source"])

    api[1].before_write = race
    assert put(api, revision=2).status_code == 410
    assert "transcript" not in next(iter(api[1].documents.values()))["_source"]


def test_expiry_does_not_clobber_concurrent_write(api):
    put(api)
    existing = next(iter(api[1].documents.values()))
    existing["_source"]["expires_at"] = (NOW - timedelta(seconds=1)).isoformat()

    def race(doc_id):
        api[1].before_write = None
        api[1].documents[doc_id]["_seq_no"] += 1

    api[1].before_write = race
    assert asyncio.run(api[2].expire()) == {"expired": 0, "scanned": 1}


def test_validation_errors_do_not_echo_transcript(api):
    secret = "sensitive " * 3000
    response = put(api, transcript=secret)
    assert response.status_code == 422
    assert "sensitive" not in response.text
