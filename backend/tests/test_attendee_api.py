import copy
from datetime import UTC, datetime, timedelta
from unittest.mock import Mock, create_autospec

import pytest
from elastic_transport import ApiResponseMeta, ConnectionError, HttpHeaders, NodeConfig
from elasticsearch import ApiError, ConflictError, Elasticsearch, NotFoundError
from fastapi.testclient import TestClient
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import SimpleSpanProcessor
from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter

from backend.attendee.auth import hash_token, person_id
from backend.config import Settings
from backend.main import create_app

CONFERENCE = "cnh"
PROFILE = {"handle": "ada", "conference": CONFERENCE, "interests": "eBPF", "topics": ["eBPF"]}
MOMENT = {
    "conference": CONFERENCE,
    "gist": "Autoscaling on custom metrics is easier than expected.",
    "topics": ["Kubernetes", "Autoscaling"],
    "source": "spoken",
    "approved": True,
}
PEOPLE_FIELDS = {
    "conference",
    "handle",
    "token_hash",
    "interests",
    "topics",
    "starred_talks",
    "last_active",
    "expires_at",
}
MOMENT_FIELDS = {"conference", "handle", "source", "gist", "topics", "at", "expires_at"}
LEAK = "secret stored text and API key"
EMPTY = {"timed_out": False, "_shards": {"failed": 0}, "hits": {"hits": []}}


def error(kind, status, body):
    meta = ApiResponseMeta(
        status=status,
        http_version="1.1",
        headers=HttpHeaders(),
        duration=0.0,
        node=NodeConfig("https", "elastic.example", 443),
    )
    return kind(LEAK, meta, body)


def failure():
    return error(ApiError, 500, {"error": LEAK})


class Elastic:
    # autospec makes any keyword the real client does not accept fail the test.
    def __init__(self):
        self.client = create_autospec(Elasticsearch, instance=True)
        self.client.indices = Mock()
        self.client.indices.exists.return_value = True
        self.client.get.side_effect = self.get
        self.client.index.side_effect = self.index
        self.client.search.return_value = copy.deepcopy(EMPTY)
        self.people = {}
        self.moments = {}

    def get(self, *, index, id):
        assert index == "people"
        if id not in self.people:
            raise error(NotFoundError, 404, {"found": False})
        return copy.deepcopy(self.people[id])

    def index(self, *, index, id, document, **guard):
        store = self.people if index == "people" else self.moments
        if guard.get("op_type") == "create" and id in store:
            raise error(ConflictError, 409, {"error": LEAK})
        if "if_seq_no" in guard and guard["if_seq_no"] != store[id]["_seq_no"]:
            raise error(ConflictError, 409, {"error": LEAK})
        seq_no = store[id]["_seq_no"] + 1 if id in store else 0
        store[id] = {"_id": id, "_source": document, "_seq_no": seq_no, "_primary_term": 1}
        return {"result": "created"}

    def stored_person(self, handle="ada", conference=CONFERENCE):
        return self.people[person_id(conference, handle)]["_source"]

    @property
    def calls(self):
        return len(self.client.mock_calls)


@pytest.fixture
def elastic(monkeypatch):
    double = Elastic()
    monkeypatch.setattr("backend.attendee.elastic.get_elasticsearch_client", lambda: double.client)
    return double


@pytest.fixture
def client(elastic):
    with TestClient(create_app(Settings())) as test_client:
        yield test_client


def bearer(token):
    return {"Authorization": "Bearer " + token}


def register(client, **changes):
    response = client.put("/me", json=PROFILE | changes)
    assert response.status_code == 201
    return bearer(response.json()["token"])


def filters(elastic):
    return elastic.client.search.call_args.kwargs["query"]["bool"]["filter"]


def test_put_me_creates_profile_and_returns_token_once(client, elastic):
    response = client.put("/me", json=PROFILE | {"starred_talks": ["talk:1"]})
    body = response.json()
    assert response.status_code == 201
    assert response.headers["Cache-Control"] == "no-store"
    assert body["created"] is True and body["handle"] == "ada" and body["starred_talks"] == ["talk:1"]
    assert "token_hash" not in body
    stored = elastic.stored_person()
    assert set(stored) == PEOPLE_FIELDS
    assert stored["token_hash"] == hash_token(body["token"])
    assert body["token"] not in str(stored)
    assert elastic.client.index.call_args.kwargs["op_type"] == "create"


def test_put_me_owner_can_update_without_changing_token(client, elastic):
    headers = register(client)
    original = elastic.stored_person()["token_hash"]
    response = client.put("/me", json=PROFILE | {"interests": "Rust", "topics": []}, headers=headers)
    assert response.status_code == 200
    assert response.json()["created"] is False and "token" not in response.json()
    assert elastic.stored_person()["interests"] == "Rust"
    assert elastic.stored_person()["token_hash"] == original
    assert elastic.client.index.call_args.kwargs["if_seq_no"] == 0


def test_put_me_omits_empty_interests_for_semantic_text(client, elastic):
    register(client, interests="")
    assert "interests" not in elastic.stored_person()


def test_put_me_cannot_claim_existing_handle_without_token(client, elastic):
    register(client)
    before = elastic.stored_person()
    response = client.put("/me", json=PROFILE | {"interests": "hijacked"})
    assert response.status_code == 409
    assert "token" not in response.json()
    assert elastic.stored_person() == before


def test_put_me_another_attendees_token_cannot_overwrite(client, elastic):
    register(client)
    mallory = register(client, handle="mallory")
    before = elastic.stored_person()
    assert client.put("/me", json=PROFILE | {"interests": "x"}, headers=mallory).status_code == 403
    assert elastic.stored_person() == before


def test_put_me_forged_secret_with_victims_id_is_rejected(client, elastic):
    register(client)
    before = elastic.stored_person()
    forged = person_id(CONFERENCE, "ada") + "." + "a" * 43
    assert client.put("/me", json=PROFILE | {"interests": "x"}, headers=bearer(forged)).status_code == 401
    assert elastic.stored_person() == before


@pytest.mark.parametrize("header", ["", "Bearer nope", "Basic abc", "Bearer " + "a" * 64])
def test_put_me_malformed_authorization_never_reaches_elastic(client, elastic, header):
    assert client.put("/me", json=PROFILE, headers={"Authorization": header}).status_code == 401
    assert elastic.calls == 0


def test_put_me_token_for_deleted_profile_is_rejected(client, elastic):
    headers = register(client)
    elastic.people.clear()
    assert client.put("/me", json=PROFILE, headers=headers).status_code == 401
    assert not elastic.people


def test_put_me_concurrent_claim_loses_cleanly(client, elastic):
    def race(*, index, id):
        elastic.client.get.side_effect = elastic.get
        raise error(NotFoundError, 404, {"found": False})

    register(client)
    elastic.client.get.side_effect = race
    response = client.put("/me", json=PROFILE)
    assert response.status_code == 409
    assert "token" not in response.json()


def test_put_me_concurrent_update_conflicts(client, elastic):
    headers = register(client)
    original = elastic.client.get.side_effect

    def stale(*, index, id):
        hit = original(index=index, id=id)
        elastic.people[id]["_seq_no"] += 1
        return hit

    elastic.client.get.side_effect = stale
    assert client.put("/me", json=PROFILE, headers=headers).status_code == 409


@pytest.mark.parametrize(
    "changes",
    [
        {"handle": "a"},
        {"handle": "../victim"},
        {"handle": "x" * 33},
        {"conference": "*"},
        {"interests": "x" * 1001},
        {"topics": ["t"] * 21},
        {"topics": ["x" * 65]},
        {"topics": ["bad\ntopic"]},
        {"starred_talks": ["*"]},
        {"token_hash": "chosen"},
        {"expires_at": "2099-01-01T00:00:00Z"},
    ],
)
def test_put_me_rejects_invalid_input(client, elastic, changes):
    assert client.put("/me", json=PROFILE | changes).status_code == 422
    assert not elastic.people


def test_put_me_deduplicates_topic_case_variants(client, elastic):
    register(client, topics=["eBPF", "ebpf", "Go"])
    assert elastic.stored_person()["topics"] == ["eBPF", "Go"]


def test_put_me_missing_index_does_not_auto_create(client, elastic):
    elastic.client.get.side_effect = error(NotFoundError, 404, {"error": {"type": "index_not_found_exception"}})
    assert client.put("/me", json=PROFILE).status_code == 503
    elastic.client.index.assert_not_called()


@pytest.mark.parametrize("problem", [failure(), ConnectionError(LEAK)])
def test_put_me_elastic_failure_does_not_leak(client, elastic, problem):
    elastic.client.get.side_effect = problem
    response = client.put("/me", json=PROFILE)
    assert response.status_code == 503
    assert LEAK not in response.text


def test_put_me_write_failure_does_not_return_token(client, elastic):
    elastic.client.index.side_effect = failure()
    response = client.put("/me", json=PROFILE)
    assert response.status_code == 503
    assert "token" not in response.json()


def test_endpoints_report_unconfigured_elastic(monkeypatch):
    monkeypatch.setattr("backend.attendee.elastic.get_elasticsearch_client", lambda: None)
    with TestClient(create_app(Settings())) as client:
        assert client.put("/me", json=PROFILE).status_code == 503
        assert client.get("/graph", params={"conference": CONFERENCE}).status_code == 503
        assert client.get("/search", params={"conference": CONFERENCE, "q": "ai"}).status_code == 503


def test_moment_requires_authentication(client, elastic):
    assert client.post("/moments", json=MOMENT).status_code == 401
    assert elastic.calls == 0


def test_moment_uses_authenticated_handle(client, elastic):
    headers = register(client)
    response = client.post("/moments", json=MOMENT, headers=headers)
    body = response.json()
    assert response.status_code == 201
    stored = elastic.moments[body["id"]]["_source"]
    assert set(stored) == MOMENT_FIELDS
    assert stored["handle"] == "ada"
    assert "approved" not in stored
    assert body["at"] == stored["at"]
    assert elastic.client.index.call_args.kwargs["op_type"] == "create"


def test_moment_default_expiry_is_within_retention(client, elastic):
    body = client.post("/moments", json=MOMENT, headers=register(client)).json()
    expiry = datetime.fromisoformat(body["expires_at"])
    assert datetime.now(UTC) < expiry <= datetime.now(UTC) + timedelta(days=7)


def test_moment_accepts_valid_expiry(client, elastic):
    expiry = datetime.now(UTC) + timedelta(days=1)
    response = client.post("/moments", json=MOMENT | {"expires_at": expiry.isoformat()}, headers=register(client))
    assert response.status_code == 201
    assert datetime.fromisoformat(response.json()["expires_at"]) == expiry


@pytest.mark.parametrize(
    "changes",
    [
        {"handle": "victim"},
        {"owner_id": "victim"},
        {"transcript": "full conversation"},
        {"audio": "AAAA"},
        {"approved": False},
        {"approved": "yes"},
        {"gist": " "},
        {"gist": "x" * 281},
        {"gist": "line one\nline two"},
        {"topics": []},
        {"topics": ["t1", "t2", "t3", "t4", "t5", "t6"]},
        {"source": "microphone"},
        {"conference": "*"},
        {"expires_at": "2026-11-09T13:00:00"},
    ],
)
def test_moment_rejects_invalid_or_raw_content(client, elastic, changes):
    assert client.post("/moments", json=MOMENT | changes, headers=register(client)).status_code == 422
    assert not elastic.moments


def test_moment_requires_explicit_approval(client, elastic):
    body = {key: value for key, value in MOMENT.items() if key != "approved"}
    assert client.post("/moments", json=body, headers=register(client)).status_code == 422
    assert not elastic.moments


@pytest.mark.parametrize("delta", [timedelta(seconds=-1), timedelta(days=8)])
def test_moment_rejects_out_of_range_expiry(client, elastic, delta):
    expiry = (datetime.now(UTC) + delta).isoformat()
    response = client.post("/moments", json=MOMENT | {"expires_at": expiry}, headers=register(client))
    assert response.status_code == 422
    assert not elastic.moments


def test_moment_cannot_target_another_conference(client, elastic):
    response = client.post("/moments", json=MOMENT | {"conference": "other"}, headers=register(client))
    assert response.status_code == 403
    assert not elastic.moments


def test_moment_rejects_expired_profile(client, elastic):
    headers = register(client)
    elastic.stored_person()["expires_at"] = (datetime.now(UTC) - timedelta(seconds=1)).isoformat()
    assert client.post("/moments", json=MOMENT, headers=headers).status_code == 401


def test_moment_missing_index_does_not_auto_create(client, elastic):
    headers = register(client)
    elastic.client.indices.exists.return_value = False
    assert client.post("/moments", json=MOMENT, headers=headers).status_code == 503
    assert not elastic.moments


def test_moment_elastic_failure_does_not_leak(client, elastic):
    headers = register(client)
    elastic.client.indices.exists.side_effect = failure()
    response = client.post("/moments", json=MOMENT, headers=headers)
    assert response.status_code == 503
    assert LEAK not in response.text


def graph_response():
    def bucket(key, count, related):
        buckets = [{"key": name, "doc_count": weight} for name, weight in related]
        return {"key": key, "doc_count": count, "related": {"buckets": buckets}}

    return EMPTY | {
        "aggregations": {
            "topics": {
                "buckets": [
                    bucket("Kubernetes", 9, [("Kubernetes", 9), ("eBPF", 3), ("Outside", 2)]),
                    bucket("eBPF", 4, [("eBPF", 4), ("Kubernetes", 3)]),
                ]
            }
        }
    }


def test_graph_returns_nodes_and_deduplicated_edges(client, elastic):
    elastic.client.search.return_value = graph_response()
    response = client.get("/graph", params={"conference": CONFERENCE})
    assert response.status_code == 200
    assert response.json() == {
        "conference": CONFERENCE,
        "nodes": [
            {"id": "Kubernetes", "label": "Kubernetes", "count": 9},
            {"id": "eBPF", "label": "eBPF", "count": 4},
        ],
        "edges": [{"source": "Kubernetes", "target": "eBPF", "weight": 3}],
    }
    call = elastic.client.search.call_args.kwargs
    assert call["index"] == "talks,moments" and call["size"] == 0
    assert {"term": {"conference": CONFERENCE}} in filters(elastic)
    assert call["aggregations"]["topics"]["terms"]["field"] == "topics"


def test_graph_never_requests_attendee_documents(client, elastic):
    client.get("/graph", params={"conference": CONFERENCE})
    call = elastic.client.search.call_args.kwargs
    assert call["size"] == 0
    assert "people" not in call["index"] and "alerts" not in call["index"]
    assert "handle" not in str(call["aggregations"])


def test_graph_empty_when_indices_are_missing(client, elastic):
    response = client.get("/graph", params={"conference": CONFERENCE})
    assert response.status_code == 200
    assert response.json()["nodes"] == [] and response.json()["edges"] == []


@pytest.mark.parametrize("params", [{}, {"conference": "*"}, {"conference": CONFERENCE, "limit": 101}])
def test_graph_rejects_invalid_input(client, elastic, params):
    assert client.get("/graph", params=params).status_code == 422
    assert elastic.calls == 0


@pytest.mark.parametrize("result", [failure(), ConnectionError(LEAK)])
def test_graph_elastic_failure_does_not_leak(client, elastic, result):
    elastic.client.search.side_effect = result
    response = client.get("/graph", params={"conference": CONFERENCE})
    assert response.status_code == 503
    assert LEAK not in response.text


def test_graph_partial_result_is_not_success(client, elastic):
    elastic.client.search.return_value = EMPTY | {"timed_out": True}
    assert client.get("/graph", params={"conference": CONFERENCE}).status_code == 503


SEARCH_HITS = [
    {
        "_index": "talks",
        "_id": "t1",
        "_score": 8.5,
        "_source": {"title": "eBPF in prod", "abstract": "Tracing", "topics": ["eBPF"], "speakers": ["Grace"]},
    },
    {
        "_index": "moments",
        "_id": "m1",
        "_score": 0.7,
        "_source": {"gist": "eBPF is fun", "topics": ["eBPF"], "source": "spoken", "at": "2026-11-09T12:00:00Z"},
    },
]
SEARCH = {"conference": CONFERENCE, "q": "eBPF"}


def test_search_returns_ranked_results_with_types(client, elastic):
    elastic.client.search.return_value = EMPTY | {"hits": {"hits": SEARCH_HITS}}
    response = client.get("/search", params=SEARCH)
    body = response.json()
    assert response.status_code == 200
    assert body["mode"] == "hybrid"
    assert [(hit["type"], hit["id"], hit["score"]) for hit in body["results"]] == [
        ("talk", "t1", 8.5),
        ("moment", "m1", 0.7),
    ]
    assert body["results"][0]["title"] == "eBPF in prod"
    assert body["results"][1]["gist"] == "eBPF is fun"
    assert "gist" not in body["results"][0]


def test_search_filters_conference_and_never_requests_handles(client, elastic):
    client.get("/search", params=SEARCH)
    call = elastic.client.search.call_args.kwargs
    assert {"term": {"conference": CONFERENCE}} in filters(elastic)
    assert call["index"] == "talks,moments"
    assert "handle" not in call["source"]
    assert "query_string" not in str(call["query"])


def test_search_falls_back_to_keyword_when_inference_fails(client, elastic):
    elastic.client.search.side_effect = [failure(), EMPTY | {"hits": {"hits": SEARCH_HITS[:1]}}]
    response = client.get("/search", params=SEARCH)
    assert response.status_code == 200
    assert response.json()["mode"] == "keyword"
    assert len(response.json()["results"]) == 1
    fallback = str(elastic.client.search.call_args.kwargs["query"])
    assert "gist" not in fallback and "content" not in fallback


def test_search_empty_results(client, elastic):
    response = client.get("/search", params=SEARCH)
    assert response.status_code == 200
    assert response.json()["results"] == []


def test_search_both_attempts_failing_does_not_leak(client, elastic):
    elastic.client.search.side_effect = failure()
    response = client.get("/search", params=SEARCH)
    assert response.status_code == 503
    assert LEAK not in response.text


def test_search_outage_does_not_retry(client, elastic):
    elastic.client.search.side_effect = ConnectionError(LEAK)
    assert client.get("/search", params=SEARCH).status_code == 503
    assert elastic.client.search.call_count == 1


@pytest.mark.parametrize(
    "params",
    [
        {"conference": CONFERENCE},
        {"q": "ai"},
        {"conference": CONFERENCE, "q": "   "},
        {"conference": CONFERENCE, "q": "x" * 201},
        {"conference": CONFERENCE, "q": "ai", "limit": 51},
        {"conference": "*", "q": "ai"},
    ],
)
def test_search_rejects_invalid_input(client, elastic, params):
    assert client.get("/search", params=params).status_code == 422
    assert elastic.calls == 0


def test_post_search_service_contract_is_unchanged(client, elastic):
    body = {"conference": CONFERENCE, "interests": "AI"}
    assert client.post("/search", json=body).status_code == 503
    settings = Settings(service_token="test-service-token-32-characters-long")
    with TestClient(create_app(settings)) as service:
        assert service.post("/search", json=body).status_code == 401
    assert elastic.calls == 0


def test_search_terms_do_not_reach_traces(elastic):
    exporter = InMemorySpanExporter()
    provider = TracerProvider()
    provider.add_span_processor(SimpleSpanProcessor(exporter))
    app = create_app(Settings())
    FastAPIInstrumentor.instrument_app(app, tracer_provider=provider)
    with TestClient(app) as client:
        assert client.get("/search", params={"conference": CONFERENCE, "q": "privateterm"}).status_code == 200
    spans = exporter.get_finished_spans()
    assert spans
    assert "privateterm" not in str([dict(span.attributes) for span in spans])


def test_feed_requires_authentication(client, elastic):
    assert client.get("/feed").status_code == 401
    assert elastic.calls == 0


def alert(alert_id, at):
    source = {"kind": "talk", "room": "topic:ebpf", "why": "Shared topic", "seen": False, "at": at}
    return {"_id": alert_id, "_source": source, "_score": None}


def test_feed_returns_own_alerts_newest_first(client, elastic):
    headers = register(client)
    hits = [alert("a2", "2026-11-09T13:00:00Z"), alert("a1", "2026-11-09T12:00:00Z")]
    elastic.client.search.return_value = EMPTY | {"hits": {"hits": hits}}
    response = client.get("/feed", params={"limit": 2}, headers=headers)
    assert response.status_code == 200
    assert [item["id"] for item in response.json()["alerts"]] == ["a2", "a1"]
    assert "to_handle" not in response.text
    call = elastic.client.search.call_args.kwargs
    assert call["index"] == "alerts" and call["size"] == 2
    assert call["sort"] == [{"at": {"order": "desc", "unmapped_type": "date"}}]
    assert {"term": {"to_handle": "ada"}} in filters(elastic)
    assert {"term": {"conference": CONFERENCE}} in filters(elastic)


def test_feed_ignores_attempts_to_read_another_handle(client, elastic):
    headers = register(client)
    response = client.get("/feed", params={"handle": "victim", "to_handle": "victim"}, headers=headers)
    assert response.status_code == 200
    assert {"term": {"to_handle": "ada"}} in filters(elastic)
    assert "victim" not in str(filters(elastic))


def test_feed_rejects_other_conference(client, elastic):
    headers = register(client)
    assert client.get("/feed", params={"conference": "other"}, headers=headers).status_code == 403
    elastic.client.search.assert_not_called()


def test_feed_rejects_forged_token_for_another_attendee(client, elastic):
    register(client)
    forged = person_id(CONFERENCE, "ada") + "." + "a" * 43
    assert client.get("/feed", headers=bearer(forged)).status_code == 401
    elastic.client.search.assert_not_called()


def test_feed_empty_results(client, elastic):
    response = client.get("/feed", headers=register(client))
    assert response.status_code == 200
    assert response.json() == {"alerts": []}


@pytest.mark.parametrize("limit", [0, 101])
def test_feed_rejects_invalid_limit(client, elastic, limit):
    assert client.get("/feed", params={"limit": limit}, headers=register(client)).status_code == 422


def test_feed_elastic_failure_does_not_leak(client, elastic):
    headers = register(client)
    elastic.client.search.side_effect = failure()
    response = client.get("/feed", headers=headers)
    assert response.status_code == 503
    assert LEAK not in response.text


def test_auth_elastic_failure_is_unavailable_not_unauthorized(client, elastic):
    headers = register(client)
    elastic.client.get.side_effect = failure()
    assert client.get("/feed", headers=headers).status_code == 503


def test_existing_routes_still_respond(client, elastic):
    assert client.get("/healthz").json() == {"status": "healthy"}
    assert client.get("/readyz").json() == {"status": "ready", "vector_search": "disabled"}
