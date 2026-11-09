"""Storage contract tests, including real Elasticsearch client argument validation."""

import copy
from datetime import UTC, datetime, timedelta

import pytest
from elastic_transport import ConnectionError
from elasticsearch import ConflictError, NotFoundError
from fastapi.testclient import TestClient

from backend.attendee.auth import Attendee
from backend.attendee.transcripts import segment_document_id
from backend.config import Settings
from backend.main import create_app
from backend.tests.test_attendee_api import LEAK, Elastic, error, failure, register

PATH = "/transcripts/device-stream/segments/0"
BODY = {"revision": 1, "transcript": "First partial", "consent": True}
OWNER = Attendee(conference="cnh", handle="ada")


class TranscriptElastic(Elastic):
    def __init__(self):
        super().__init__()
        self.conversations = {}
        self.client.search.side_effect = self.search

    def get(self, *, index, id):
        if index == "people":
            return super().get(index=index, id=id)
        assert index == "conversations"
        if id not in self.conversations:
            raise error(NotFoundError, 404, {"found": False})
        return copy.deepcopy(self.conversations[id])

    def index(self, *, index, id, document, **guard):
        if index == "people":
            return super().index(index=index, id=id, document=document, **guard)
        assert index == "conversations"
        assert set(document) == {
            "conference", "handle", "conversation_id", "revision", "transcript",
            "consent", "visibility", "is_final", "topics", "updated_at", "expires_at",
        }
        assert guard["refresh"] == "wait_for"
        old = self.conversations.get(id)
        if guard.get("op_type") == "create" and old:
            raise error(ConflictError, 409, {})
        if "if_seq_no" in guard:
            assert guard["if_primary_term"] == 1
            if guard["if_seq_no"] != old["_seq_no"]:
                raise error(ConflictError, 409, {})
        self.conversations[id] = {
            "_id": id, "_source": copy.deepcopy(document),
            "_seq_no": old["_seq_no"] + 1 if old else 0, "_primary_term": 1,
        }
        return {"result": "updated" if old else "created"}

    def search(self, *, query, size, sort, **kwargs):
        assert kwargs["index"] == "conversations"
        assert kwargs["allow_partial_search_results"] is False
        assert kwargs["ignore_unavailable"] is False
        assert sort == [{"conversation_id": "asc"}]
        hits = list(copy.deepcopy(self.conversations).values())
        for clause in query["bool"]["filter"]:
            if "term" in clause:
                field, value = next(iter(clause["term"].items()))
                hits = [hit for hit in hits if hit["_source"][field] == value]
            elif "prefix" in clause:
                field, value = next(iter(clause["prefix"].items()))
                hits = [hit for hit in hits if hit["_source"][field].startswith(value)]
            elif "range" in clause:
                field, bounds = next(iter(clause["range"].items()))
                value = bounds["gt"]
                if field == "expires_at":
                    hits = [hit for hit in hits if datetime.fromisoformat(hit["_source"][field]) > datetime.now(UTC)]
                else:
                    hits = [hit for hit in hits if hit["_source"][field] > value]
        hits.sort(key=lambda hit: hit["_source"]["conversation_id"])
        return {"hits": {"hits": hits[:size]}, "_shards": {"failed": 0}, "timed_out": False}


@pytest.fixture
def elastic(monkeypatch):
    double = TranscriptElastic()
    monkeypatch.setattr("backend.attendee.elastic.get_elasticsearch_client", lambda: double.client)
    return double


@pytest.fixture
def client(elastic):
    with TestClient(create_app(Settings())) as client:
        yield client


def stored(elastic, sequence=0):
    return elastic.conversations[segment_document_id(OWNER, "device-stream", sequence)]["_source"]


def test_partial_saved_before_final_and_replaced_without_duplicates(client, elastic):
    headers = register(client)
    first = client.put(PATH, json=BODY, headers=headers)
    assert first.status_code == 200 and first.json()["result"] == "created"
    assert first.headers["cache-control"] == "no-store"
    assert stored(elastic)["is_final"] is False
    assert client.get(PATH, headers=headers).json()["transcript"] == "First partial"
    expiry = stored(elastic)["expires_at"]
    final = BODY | {"revision": 3, "transcript": "First partial corrected and finished", "finalized": True}
    assert client.put(PATH, json=final, headers=headers).json()["result"] == "updated"
    assert stored(elastic)["transcript"] == final["transcript"]
    assert stored(elastic)["expires_at"] == expiry
    assert len(elastic.conversations) == 1
    assert stored(elastic)["visibility"] == "private"
    assert stored(elastic)["handle"] == "ada"
    assert datetime.now(UTC) < datetime.fromisoformat(expiry) <= datetime.now(UTC) + timedelta(days=7)


@pytest.mark.parametrize("finalized", [False, True])
def test_duplicate_retries_do_not_rewrite_or_reembed(client, elastic, finalized):
    headers = register(client)
    body = BODY | {"finalized": finalized}
    client.put(PATH, json=body, headers=headers)
    snapshot = copy.deepcopy(elastic.conversations)
    elastic.client.index.reset_mock()
    assert client.put(PATH, json=body, headers=headers).json()["result"] == "unchanged"
    elastic.client.index.assert_not_called()
    assert elastic.conversations == snapshot


@pytest.mark.parametrize("change", [
    {"revision": 1}, {"revision": 2, "transcript": "Conflicting text"},
    {"revision": 2, "finalized": True},
])
def test_stale_or_conflicting_revisions_rejected(client, elastic, change):
    headers = register(client)
    client.put(PATH, json=BODY | {"revision": 2}, headers=headers)
    elastic.client.index.reset_mock()
    response = client.put(PATH, json=BODY | change, headers=headers)
    assert response.status_code == 409
    elastic.client.index.assert_not_called()


def test_finalized_segment_is_immutable(client, elastic):
    headers = register(client)
    client.put(PATH, json=BODY | {"finalized": True}, headers=headers)
    assert client.put(PATH, json=BODY | {"revision": 2}, headers=headers).status_code == 409
    assert stored(elastic)["is_final"] is True


def test_history_appends_in_sequence_order_and_paginates(client, elastic):
    headers = register(client)
    for sequence in [10, 0, 2]:
        body = BODY | {"transcript": f"Recording {sequence}", "finalized": True}
        assert client.put(f"/transcripts/device-stream/segments/{sequence}", json=body, headers=headers).status_code == 200
    page = client.get("/transcripts/device-stream?limit=2", headers=headers)
    assert page.headers["cache-control"] == "no-store"
    assert [item["sequence"] for item in page.json()["segments"]] == [0, 2]
    assert page.json()["next_after"] == 2
    second = client.get("/transcripts/device-stream?limit=2&after=2", headers=headers).json()
    assert [item["sequence"] for item in second["segments"]] == [10]
    assert second["next_after"] is None
    assert len(elastic.conversations) == 3
    assert stored(elastic)["transcript"] == "Recording 0"


def test_owners_conferences_and_streams_are_isolated(client, elastic):
    ada = register(client)
    bob = register(client, handle="bob")
    other_conference = register(client, conference="other")
    for headers, text in [(ada, "Ada private"), (bob, "Bob private"), (other_conference, "Other private")]:
        client.put(PATH, json=BODY | {"transcript": text}, headers=headers)
    client.put("/transcripts/other-stream/segments/0", json=BODY, headers=ada)
    assert len(elastic.conversations) == 4
    for headers, text in [(ada, "Ada private"), (bob, "Bob private"), (other_conference, "Other private")]:
        page = client.get("/transcripts/device-stream?handle=bob&conference=other", headers=headers).json()
        assert [segment["transcript"] for segment in page["segments"]] == [text]
        assert client.get(PATH, headers=headers).json()["transcript"] == text


@pytest.mark.parametrize("method,path", [("put", PATH), ("get", PATH), ("get", "/transcripts/device-stream")])
def test_authentication_required(client, elastic, method, path):
    kwargs = {"json": BODY} if method == "put" else {}
    assert client.request(method, path, **kwargs).status_code == 401
    assert elastic.calls == 0
    headers = register(client)
    forged = {"Authorization": headers["Authorization"][:-43] + "a" * 43}
    assert client.request(method, path, headers=forged, **kwargs).status_code == 401
    elastic.stored_person()["expires_at"] = (datetime.now(UTC) - timedelta(days=1)).isoformat()
    assert client.request(method, path, headers=headers, **kwargs).status_code == 401
    assert not elastic.conversations


@pytest.mark.parametrize("change", [
    {"revision": 0}, {"revision": True}, {"revision": "2"}, {"revision": 2**63},
    {"transcript": ""}, {"transcript": "   "}, {"transcript": "x" * 20001},
    {"consent": False}, {"consent": 1}, {"consent": "true"},
    {"finalized": "true"}, {"owner_id": "victim"}, {"handle": "victim"},
    {"conference": "other"}, {"visibility": "conference"}, {"audio": "data"},
])
def test_invalid_payloads_do_not_write_or_echo_text(client, elastic, change):
    headers = register(client)
    response = client.put(PATH, json=BODY | change, headers=headers)
    assert response.status_code == 422
    assert BODY["transcript"] not in response.text
    assert not elastic.conversations


def test_consent_cannot_be_omitted(client, elastic):
    body = {key: value for key, value in BODY.items() if key != "consent"}
    assert client.put(PATH, json=body, headers=register(client)).status_code == 422


@pytest.mark.parametrize("path", [
    "/transcripts/*/segments/0", "/transcripts/device-stream/segments/-1",
    "/transcripts/device-stream/segments/2147483648", "/transcripts/device-stream/segments/not-an-integer",
])
def test_invalid_identifiers(client, elastic, path):
    assert client.put(path, json=BODY, headers=register(client)).status_code == 422
    assert not elastic.conversations


@pytest.mark.parametrize("params", [{"limit": 0}, {"limit": 51}, {"after": -1}, {"after": 2147483648}])
def test_invalid_pagination(client, elastic, params):
    assert client.get("/transcripts/device-stream", params=params, headers=register(client)).status_code == 422
    elastic.client.search.assert_not_called()


def test_expiry_hides_history_and_blocks_resurrection(client, elastic):
    headers = register(client)
    client.put(PATH, json=BODY, headers=headers)
    stored(elastic)["expires_at"] = (datetime.now(UTC) - timedelta(seconds=1)).isoformat()
    assert client.get(PATH, headers=headers).status_code == 404
    assert client.get("/transcripts/device-stream", headers=headers).json()["segments"] == []
    assert client.put(PATH, json=BODY | {"revision": 2}, headers=headers).status_code == 410


def test_missing_segment_and_empty_history(client, elastic):
    headers = register(client)
    assert client.get(PATH, headers=headers).status_code == 404
    assert client.get("/transcripts/device-stream", headers=headers).json() == {
        "stream_id": "device-stream", "segments": [], "next_after": None,
    }


def test_missing_index_does_not_silently_create(client, elastic):
    headers = register(client)
    def get(**kwargs):
        if kwargs["index"] == "people":
            return elastic.get(**kwargs)
        raise error(NotFoundError, 404, {"error": {"type": "index_not_found_exception"}})
    elastic.client.get.side_effect = get
    elastic.client.index.reset_mock()
    assert client.put(PATH, json=BODY, headers=headers).status_code == 503
    elastic.client.index.assert_not_called()


@pytest.mark.parametrize("problem", [failure(), ConnectionError(LEAK)])
def test_database_failure_does_not_acknowledge_or_leak(client, elastic, problem):
    headers = register(client)
    elastic.client.index.side_effect = problem
    response = client.put(PATH, json=BODY, headers=headers)
    assert response.status_code == 503 and LEAK not in response.text
    assert not elastic.conversations


@pytest.mark.parametrize("problem", [
    {"timed_out": True}, {"_shards": {"failed": 1}},
])
def test_partial_reads_fail_closed(client, elastic, problem):
    headers = register(client)
    elastic.client.search.side_effect = None
    elastic.client.search.return_value = {"hits": {"hits": []}} | problem
    assert client.get("/transcripts/device-stream", headers=headers).status_code == 503


def test_missing_index_history_is_unavailable_not_empty(client, elastic):
    headers = register(client)
    elastic.client.search.side_effect = error(NotFoundError, 404, {"error": {"type": "index_not_found_exception"}})
    assert client.get("/transcripts/device-stream", headers=headers).status_code == 503


def test_concurrent_same_revision_retry_is_idempotent(client, elastic):
    headers = register(client)
    def race(**kwargs):
        elastic.index(**kwargs)
        raise error(ConflictError, 409, {})
    elastic.client.index.side_effect = race
    assert client.put(PATH, json=BODY, headers=headers).json()["result"] == "unchanged"
    assert elastic.client.index.call_count == 2  # profile plus single segment attempt
    assert len(elastic.conversations) == 1


def test_concurrent_newer_revision_cannot_be_overwritten(client, elastic):
    headers = register(client)
    def race(**kwargs):
        kwargs["document"]["revision"] = 2
        kwargs["document"]["transcript"] = "Newer text"
        elastic.index(**kwargs)
        raise error(ConflictError, 409, {})
    elastic.client.index.side_effect = race
    assert client.put(PATH, json=BODY, headers=headers).status_code == 409
    assert stored(elastic)["transcript"] == "Newer text"


def test_conflict_retries_are_bounded(client, elastic):
    headers = register(client)
    elastic.client.index.reset_mock()
    elastic.client.index.side_effect = error(ConflictError, 409, {})
    assert client.put(PATH, json=BODY, headers=headers).status_code == 409
    assert elastic.client.index.call_count == 3
