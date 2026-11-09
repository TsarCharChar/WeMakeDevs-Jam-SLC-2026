"""GET /recommendations: the caller's closest topics, from their own notes, without exposing them."""

import pytest
from elastic_transport import ConnectionError
from fastapi.testclient import TestClient

from backend.config import Settings
from backend.main import create_app
from backend.tests.test_attendee_api import CONFERENCE, EMPTY, LEAK, Elastic, failure, register

NOTE = "We traced a latency spike with eBPF and no restart."
OLDER_NOTE = "GPU scheduling on shared clusters."
HITS = [
    {
        "_index": "talks",
        "_id": "t1",
        "_score": 8.5,
        "_source": {"title": "eBPF in prod", "abstract": "Tracing", "topics": ["eBPF", "Observability"], "speakers": ["Grace"]},
    },
    {
        "_index": "talks",
        "_id": "t2",
        "_score": 6.0,
        "_source": {"title": "Tracing at scale", "abstract": "Spans", "topics": ["Observability"]},
    },
    {
        "_index": "moments",
        "_id": "m1",
        "_score": 0.7,
        "_source": {"gist": "eBPF is fun", "topics": ["ebpf"], "source": "spoken", "at": "2026-11-09T12:00:00Z"},
    },
]


def found(*sources):
    return EMPTY | {"hits": {"hits": [{"_id": str(index), "_source": source} for index, source in enumerate(sources)]}}


def people(**counts):
    buckets = [{"key": topic, "doc_count": count} for topic, count in counts.items()]
    return EMPTY | {"aggregations": {"topics": {"buckets": buckets}}}


NOTES = found({"transcript": NOTE}, {"transcript": OLDER_NOTE})
CONTENT = EMPTY | {"hits": {"hits": HITS}}
PEOPLE = people(Observability=3, eBPF=2, EBPF=1, Wasm=9)


@pytest.fixture
def elastic(monkeypatch):
    double = Elastic()
    monkeypatch.setattr("backend.attendee.elastic.get_elasticsearch_client", lambda: double.client)
    return double


@pytest.fixture
def client(elastic):
    with TestClient(create_app(Settings())) as test_client:
        yield test_client


def searches(elastic):
    return [call.kwargs for call in elastic.client.search.call_args_list]


def test_recommendations_require_authentication(client, elastic):
    assert client.get("/recommendations").status_code == 401
    assert elastic.calls == 0


def test_recommendations_read_only_the_callers_finalized_notes(client, elastic):
    headers = register(client)
    elastic.client.search.side_effect = [NOTES, CONTENT, PEOPLE]
    params = {"handle": "victim", "to_handle": "victim"}
    assert client.get("/recommendations", params=params, headers=headers).status_code == 200
    notes = searches(elastic)[0]
    assert notes["index"] == "conversations" and notes["source"] == ["transcript"] and notes["size"] == 5
    assert notes["sort"] == [{"updated_at": {"order": "desc", "unmapped_type": "date"}}]
    filters = notes["query"]["bool"]["filter"]
    assert {"term": {"handle": "ada"}} in filters
    assert {"term": {"conference": CONFERENCE}} in filters
    assert {"term": {"is_final": True}} in filters
    assert "victim" not in str(searches(elastic))


def test_recommendations_return_topics_first_ordered_by_closeness(client, elastic):
    headers = register(client)
    elastic.client.search.side_effect = [NOTES, CONTENT, PEOPLE]
    response = client.get("/recommendations", headers=headers)
    body = response.json()
    assert response.status_code == 200
    assert response.headers["Cache-Control"] == "no-store"
    assert body["mode"] == "hybrid"
    assert body["based_on"] == {"notes": 2, "topics": ["eBPF"], "interests": True}
    # Observability is carried by both talks (8.5 + 6.0); eBPF by one talk and one moment (8.5 + 0.7).
    assert body["topics"] == [
        {"id": "Observability", "label": "Observability", "talks": 2, "moments": 0, "people": 3, "mine": False},
        {"id": "eBPF", "label": "eBPF", "talks": 1, "moments": 1, "people": 3, "mine": True},
    ]
    assert "weight" not in response.text and "score" not in str(body["topics"])


def test_recommendations_rank_shared_content_by_notes_interests_and_topics(client, elastic):
    headers = register(client)
    elastic.client.search.side_effect = [NOTES, CONTENT, PEOPLE]
    body = client.get("/recommendations", params={"limit": 2}, headers=headers).json()
    assert [(hit["type"], hit["id"], hit["score"]) for hit in body["results"]] == [("talk", "t1", 8.5), ("talk", "t2", 6.0)]
    content = searches(elastic)[1]
    # Topics are read off a wider pool than the page of results.
    assert content["index"] == "talks,moments" and content["size"] == 40
    assert "handle" not in content["source"]
    query = content["query"]["bool"]
    text = f"{NOTE} {OLDER_NOTE} eBPF"
    assert {"match": {"content": {"query": text}}} in query["should"]
    assert {"match": {"gist": {"query": text}}} in query["should"]
    assert {"term": {"topics": {"value": "eBPF", "case_insensitive": True, "boost": 2.0}}} in query["should"]
    assert {"term": {"conference": CONFERENCE}} in query["filter"]
    assert query["must_not"] == [{"term": {"handle": "ada"}}]
    assert query["minimum_should_match"] == 1


def test_recommendations_count_other_people_per_topic_without_reading_handles(client, elastic):
    headers = register(client)
    elastic.client.search.side_effect = [NOTES, CONTENT, PEOPLE]
    client.get("/recommendations", headers=headers)
    count = searches(elastic)[2]
    assert count["index"] == "people" and count["size"] == 0
    assert "source" not in count
    assert count["aggs"] == {"topics": {"terms": {"field": "topics", "size": 500}}}
    assert {"term": {"conference": CONFERENCE}} in count["query"]["bool"]["filter"]
    assert count["query"]["bool"]["must_not"] == [{"term": {"handle": "ada"}}]


def test_recommendations_never_echo_note_text_or_handles(client, elastic):
    headers = register(client)
    elastic.client.search.side_effect = [NOTES, CONTENT, PEOPLE]
    response = client.get("/recommendations", headers=headers)
    assert NOTE not in response.text and OLDER_NOTE not in response.text
    assert "handle" not in response.text and "ada" not in response.text


def test_recommendations_bound_the_embedded_text(client, elastic):
    headers = register(client)
    elastic.client.search.side_effect = [found({"transcript": "x" * 5000}), CONTENT, PEOPLE]
    assert client.get("/recommendations", headers=headers).status_code == 200
    should = searches(elastic)[1]["query"]["bool"]["should"]
    semantic = [clause["match"]["content"]["query"] for clause in should if "content" in clause.get("match", {})]
    keyword = [clause["multi_match"]["query"] for clause in should if "multi_match" in clause]
    assert [len(text) for text in semantic] == [2000]
    assert [len(text) for text in keyword] == [300]


def test_recommendations_return_at_most_twelve_topics(client, elastic):
    headers = register(client)
    many = [
        {"_index": "talks", "_id": f"t{index}", "_score": 30.0 - index, "_source": {"title": "T", "topics": [f"topic-{index}"]}}
        for index in range(20)
    ]
    elastic.client.search.side_effect = [NOTES, EMPTY | {"hits": {"hits": many}}, people()]
    body = client.get("/recommendations", headers=headers).json()
    assert [topic["label"] for topic in body["topics"]] == [f"topic-{index}" for index in range(12)]
    assert len(body["results"]) == 10


def test_recommendations_accept_object_shaped_semantic_text(client, elastic):
    headers = register(client)
    elastic.client.search.side_effect = [found({"transcript": {"text": NOTE, "inference": {}}}), CONTENT, PEOPLE]
    response = client.get("/recommendations", headers=headers)
    assert response.json()["based_on"]["notes"] == 1
    assert NOTE in str(searches(elastic)[1]["query"])


def test_recommendations_fall_back_to_keyword_when_inference_fails(client, elastic):
    headers = register(client)
    elastic.client.search.side_effect = [NOTES, failure(), EMPTY | {"hits": {"hits": HITS[:1]}}, PEOPLE]
    response = client.get("/recommendations", headers=headers)
    assert response.status_code == 200
    assert response.json()["mode"] == "keyword"
    assert len(response.json()["results"]) == 1
    assert [topic["label"] for topic in response.json()["topics"]] == ["eBPF", "Observability"]
    fallback = searches(elastic)[2]["query"]["bool"]["should"]
    assert not any("match" in clause for clause in fallback)
    assert any("multi_match" in clause for clause in fallback)
    assert any("term" in clause for clause in fallback)


def test_recommendations_use_the_profile_when_there_are_no_notes(client, elastic):
    headers = register(client)
    elastic.client.search.side_effect = [EMPTY, CONTENT, PEOPLE]
    body = client.get("/recommendations", headers=headers).json()
    assert body["based_on"] == {"notes": 0, "topics": ["eBPF"], "interests": True}
    assert body["mode"] == "hybrid" and len(body["results"]) == 3
    assert {"match": {"content": {"query": "eBPF"}}} in searches(elastic)[1]["query"]["bool"]["should"]


def test_recommendations_with_topics_only_use_keyword_mode(client, elastic):
    headers = register(client, interests="")
    elastic.client.search.side_effect = [EMPTY, CONTENT, PEOPLE]
    body = client.get("/recommendations", headers=headers).json()
    assert body["mode"] == "keyword"
    assert body["based_on"] == {"notes": 0, "topics": ["eBPF"], "interests": False}
    should = searches(elastic)[1]["query"]["bool"]["should"]
    assert should == [{"term": {"topics": {"value": "eBPF", "case_insensitive": True, "boost": 2.0}}}]


def test_recommendations_with_nothing_to_go_on_skip_the_content_search(client, elastic):
    headers = register(client, interests="", topics=[])
    response = client.get("/recommendations", headers=headers)
    assert response.status_code == 200
    assert response.json() == {
        "conference": CONFERENCE,
        "mode": "keyword",
        "based_on": {"notes": 0, "topics": [], "interests": False},
        "topics": [],
        "results": [],
    }
    assert elastic.client.search.call_count == 1


def test_recommendations_without_matches_skip_the_people_count(client, elastic):
    headers = register(client)
    elastic.client.search.side_effect = [NOTES, EMPTY]
    body = client.get("/recommendations", headers=headers).json()
    assert body["topics"] == [] and body["results"] == []
    assert elastic.client.search.call_count == 2


def test_recommendations_reject_another_conference(client, elastic):
    headers = register(client)
    assert client.get("/recommendations", params={"conference": "other"}, headers=headers).status_code == 403
    assert elastic.client.search.call_count == 0


@pytest.mark.parametrize("limit", [0, 51, "many"])
def test_recommendations_reject_invalid_limit(client, elastic, limit):
    headers = register(client)
    assert client.get("/recommendations", params={"limit": limit}, headers=headers).status_code == 422
    assert elastic.client.search.call_count == 0


@pytest.mark.parametrize("failing", [[failure()], [NOTES, failure(), failure()], [NOTES, CONTENT, failure()]])
def test_recommendations_elastic_failure_does_not_leak(client, elastic, failing):
    headers = register(client)
    elastic.client.search.side_effect = failing
    response = client.get("/recommendations", headers=headers)
    assert response.status_code == 503
    assert LEAK not in response.text and NOTE not in response.text


def test_recommendations_outage_does_not_retry(client, elastic):
    headers = register(client)
    elastic.client.search.side_effect = [NOTES, ConnectionError(LEAK)]
    assert client.get("/recommendations", headers=headers).status_code == 503
    assert elastic.client.search.call_count == 2


def test_recommendations_partial_result_is_not_success(client, elastic):
    headers = register(client)
    elastic.client.search.side_effect = [NOTES, CONTENT | {"_shards": {"failed": 1}}]
    assert client.get("/recommendations", headers=headers).status_code == 503
