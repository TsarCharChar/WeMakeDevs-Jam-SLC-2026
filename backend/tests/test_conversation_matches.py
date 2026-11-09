import copy
from datetime import UTC, datetime, timedelta

import pytest
from elastic_transport import ConnectionError
from elasticsearch import ConflictError
from fastapi.testclient import TestClient

from backend.attendee.auth import Attendee
from backend.attendee.transcripts import segment_document_id
from backend.config import Settings
from backend.main import create_app
from backend.tests.test_attendee_api import LEAK, error, failure, register
from backend.tests.test_transcripts_api import TranscriptElastic

STREAM = "device-stream"
SEGMENT = f"/transcripts/{STREAM}/segments/0"
SHARING = SEGMENT + "/sharing"
ADA = Attendee(conference="cnh", handle="ada")
BOB = Attendee(conference="cnh", handle="bob")
SHARE = {"shared": True, "participants_consented": True}
MATCH = {"conference": "cnh", "interests": "scaling container workloads"}
TEXT = "We compared Kubernetes autoscaling strategies."
SCORE = 0.9


class MatchElastic(TranscriptElastic):
    def __init__(self):
        super().__init__()
        self.client.update.side_effect = self.update

    def update(self, *, index, id, doc, if_seq_no, if_primary_term, refresh):
        assert index == "conversations" and refresh == "wait_for" and if_primary_term == 1
        old = self.conversations[id]
        if if_seq_no != old["_seq_no"]:
            raise error(ConflictError, 409, {})
        old["_source"].update(doc)
        old["_seq_no"] += 1
        return {"result": "updated"}

    def search(self, *, query, size, sort=None, **kwargs):
        if sort is not None:
            return super().search(query=query, size=size, sort=sort, **kwargs)
        assert kwargs["index"] == "conversations" and kwargs["allow_partial_search_results"] is False
        hits = []
        for doc in copy.deepcopy(self.conversations).values():
            source = doc["_source"]
            allowed = datetime.fromisoformat(source["expires_at"]) > datetime.now(UTC)
            for clause in query["bool"]["filter"]:
                if "term" in clause:
                    field, value = next(iter(clause["term"].items()))
                    allowed &= source[field] == value
            for clause in query["bool"]["must_not"]:
                field, value = next(iter(clause["term"].items()))
                allowed &= source[field] != value
            if allowed:
                visible = {key: source[key] for key in kwargs["source"] if key in source}
                hits.append({"_id": doc["_id"], "_score": SCORE, "_source": visible})
        return {"hits": {"hits": hits[:size]}, "_shards": {"failed": 0}, "timed_out": False}


@pytest.fixture
def elastic(monkeypatch):
    double = MatchElastic()
    monkeypatch.setattr("backend.attendee.elastic.get_elasticsearch_client", lambda: double.client)
    return double


@pytest.fixture
def client(elastic):
    with TestClient(create_app(Settings())) as test_client:
        yield test_client


def save(client, headers, text=TEXT, finalized=True):
    body = {"revision": 1, "transcript": text, "finalized": finalized, "consent": True}
    assert client.put(SEGMENT, json=body, headers=headers).status_code == 200


def stored(elastic, attendee=ADA):
    return elastic.conversations[segment_document_id(attendee, STREAM, 0)]["_source"]


def shared_segment(client, handle="ada", conference="cnh", text=TEXT):
    headers = register(client, handle=handle, conference=conference)
    save(client, headers, text)
    assert client.put(SHARING, json=SHARE, headers=headers).status_code == 200
    return headers


def test_sharing_requires_token(client, elastic):
    assert client.put(SHARING, json=SHARE).status_code == 401
    assert elastic.calls == 0


def test_owner_can_share_and_unshare(client, elastic):
    headers = register(client)
    save(client, headers)
    response = client.put(SHARING, json=SHARE, headers=headers)
    assert response.status_code == 200
    assert response.json() == {"stream_id": STREAM, "sequence": 0, "shared": True}
    assert response.headers["Cache-Control"] == "no-store"
    assert stored(elastic)["visibility"] == "conference"
    assert elastic.client.update.call_args.kwargs["doc"] == {"visibility": "conference"}
    assert stored(elastic)["transcript"] == TEXT
    assert client.put(SHARING, json={"shared": False}, headers=headers).json()["shared"] is False
    assert stored(elastic)["visibility"] == "private"


def test_sharing_again_does_not_rewrite(client, elastic):
    headers = shared_segment(client)
    elastic.client.update.reset_mock()
    assert client.put(SHARING, json=SHARE, headers=headers).status_code == 200
    elastic.client.update.assert_not_called()


def test_another_attendee_cannot_share_my_segment(client, elastic):
    save(client, register(client))
    mallory = register(client, handle="mallory")
    assert client.put(SHARING, json=SHARE, headers=mallory).status_code == 404
    assert stored(elastic)["visibility"] == "private"
    elastic.client.update.assert_not_called()


@pytest.mark.parametrize(
    "body",
    [
        {"shared": True},
        {"shared": True, "participants_consented": False},
        {"shared": True, "participants_consented": 1},
        {"shared": "true", "participants_consented": True},
        {"participants_consented": True},
        SHARE | {"handle": "victim"},
        SHARE | {"visibility": "conference"},
    ],
)
def test_sharing_rejects_missing_consent_or_invalid_input(client, elastic, body):
    headers = register(client)
    save(client, headers)
    assert client.put(SHARING, json=body, headers=headers).status_code == 422
    assert stored(elastic)["visibility"] == "private"


def test_partial_segment_cannot_be_shared(client, elastic):
    headers = register(client)
    save(client, headers, finalized=False)
    assert client.put(SHARING, json=SHARE, headers=headers).status_code == 409
    assert stored(elastic)["visibility"] == "private"


def test_missing_segment_cannot_be_shared(client, elastic):
    assert client.put(SHARING, json=SHARE, headers=register(client)).status_code == 404


def test_expired_segment_cannot_be_shared(client, elastic):
    headers = register(client)
    save(client, headers)
    stored(elastic)["expires_at"] = (datetime.now(UTC) - timedelta(seconds=1)).isoformat()
    assert client.put(SHARING, json=SHARE, headers=headers).status_code == 404


def test_concurrent_sharing_change_conflicts(client, elastic):
    headers = register(client)
    save(client, headers)
    elastic.client.update.side_effect = error(ConflictError, 409, {"error": LEAK})
    response = client.put(SHARING, json=SHARE, headers=headers)
    assert response.status_code == 409
    assert LEAK not in response.text


@pytest.mark.parametrize("problem", [failure(), ConnectionError(LEAK)])
def test_sharing_failure_does_not_leak(client, elastic, problem):
    headers = register(client)
    save(client, headers)
    elastic.client.update.side_effect = problem
    response = client.put(SHARING, json=SHARE, headers=headers)
    assert response.status_code == 503
    assert LEAK not in response.text


def test_shared_segment_stays_in_owner_history(client, elastic):
    headers = shared_segment(client)
    response = client.get(f"/transcripts/{STREAM}", headers=headers)
    assert response.status_code == 200
    assert [segment["transcript"] for segment in response.json()["segments"]] == [TEXT]


def test_matches_require_token(client, elastic):
    assert client.post("/matches", json=MATCH).status_code == 401
    assert elastic.calls == 0


def test_matches_reject_another_conference(client, elastic):
    response = client.post("/matches", json=MATCH | {"conference": "other"}, headers=register(client))
    assert response.status_code == 403
    elastic.client.search.assert_not_called()


def test_matches_return_shared_text_without_author(client, elastic):
    shared_segment(client, handle="bob")
    response = client.post("/matches", json=MATCH, headers=register(client))
    assert response.status_code == 200
    assert response.headers["Cache-Control"] == "no-store"
    match = response.json()["matches"][0]
    assert match["id"] == segment_document_id(BOB, STREAM, 0)
    assert match["excerpt"] == TEXT
    assert match["score"] == SCORE
    assert match["similarity"] == pytest.approx(0.8)
    assert "bob" not in response.text
    assert "handle" not in response.text


def test_matches_build_a_cosine_query_with_every_privacy_filter(client, elastic):
    client.post("/matches", json=MATCH, headers=register(client))
    call = elastic.client.search.call_args.kwargs
    assert call["query"]["bool"]["must"] == [{"match": {"transcript": {"query": MATCH["interests"]}}}]
    assert call["query"]["bool"]["filter"] == [
        {"term": {"conference": "cnh"}},
        {"term": {"visibility": "conference"}},
        {"term": {"consent": True}},
        {"term": {"is_final": True}},
        {"range": {"expires_at": {"gt": "now"}}},
    ]
    assert call["query"]["bool"]["must_not"] == [{"term": {"handle": "ada"}}]
    assert "handle" not in call["source"]


def test_matches_exclude_private_segments(client, elastic):
    save(client, register(client, handle="bob"))
    assert client.post("/matches", json=MATCH, headers=register(client)).json() == {"matches": []}


def test_matches_exclude_my_own_segments(client, elastic):
    headers = shared_segment(client)
    assert client.post("/matches", json=MATCH, headers=headers).json() == {"matches": []}


def test_matches_exclude_other_conferences(client, elastic):
    shared_segment(client, handle="bob", conference="other")
    assert client.post("/matches", json=MATCH, headers=register(client)).json() == {"matches": []}


def test_matches_exclude_partial_segments(client, elastic):
    shared_segment(client, handle="bob")
    stored(elastic, BOB)["is_final"] = False
    assert client.post("/matches", json=MATCH, headers=register(client)).json() == {"matches": []}


def test_matches_exclude_expired_segments(client, elastic):
    shared_segment(client, handle="bob")
    stored(elastic, BOB)["expires_at"] = (datetime.now(UTC) - timedelta(seconds=1)).isoformat()
    assert client.post("/matches", json=MATCH, headers=register(client)).json() == {"matches": []}


def test_unsharing_removes_a_match(client, elastic):
    bob = shared_segment(client, handle="bob")
    ada = register(client)
    assert len(client.post("/matches", json=MATCH, headers=ada).json()["matches"]) == 1
    client.put(SHARING, json={"shared": False}, headers=bob)
    assert client.post("/matches", json=MATCH, headers=ada).json() == {"matches": []}


def test_matches_cap_the_excerpt(client, elastic):
    shared_segment(client, handle="bob", text="x" * 2000)
    match = client.post("/matches", json=MATCH, headers=register(client)).json()["matches"][0]
    assert len(match["excerpt"]) == 500


def test_matches_use_saved_interests_when_none_are_sent(client, elastic):
    client.post("/matches", json={"conference": "cnh"}, headers=register(client, interests="eBPF tracing"))
    must = elastic.client.search.call_args.kwargs["query"]["bool"]["must"]
    assert must == [{"match": {"transcript": {"query": "eBPF tracing"}}}]


def test_matches_need_some_interests(client, elastic):
    response = client.post("/matches", json={"conference": "cnh"}, headers=register(client, interests=""))
    assert response.status_code == 422
    elastic.client.search.assert_not_called()


@pytest.mark.parametrize(
    "changes",
    [
        {"interests": "   "},
        {"interests": "x" * 501},
        {"limit": 0},
        {"limit": 21},
        {"limit": True},
        {"min_score": -0.1},
        {"min_score": 1.1},
        {"conference": "*"},
        {"handle": "victim"},
    ],
)
def test_matches_reject_invalid_input(client, elastic, changes):
    assert client.post("/matches", json=MATCH | changes, headers=register(client)).status_code == 422
    elastic.client.search.assert_not_called()


def test_matches_validation_does_not_echo_interests(client, elastic):
    secret = "confidential " * 100
    response = client.post("/matches", json=MATCH | {"interests": secret}, headers=register(client))
    assert response.status_code == 422
    assert "confidential" not in response.text


@pytest.mark.parametrize("problem", [failure(), ConnectionError(LEAK)])
def test_matches_failure_does_not_leak(client, elastic, problem):
    headers = register(client)
    elastic.client.search.side_effect = problem
    response = client.post("/matches", json=MATCH, headers=headers)
    assert response.status_code == 503
    assert LEAK not in response.text


def test_matches_partial_result_is_not_success(client, elastic):
    headers = register(client)
    elastic.client.search.side_effect = None
    elastic.client.search.return_value = {"timed_out": True, "hits": {"hits": []}}
    assert client.post("/matches", json=MATCH, headers=headers).status_code == 503
