"""Room chat: post and read messages in a topic or talk room without exposing handles."""

import pytest
from fastapi.testclient import TestClient

from backend.attendee.auth import person_id
from backend.config import Settings
from backend.main import create_app
from backend.tests.test_attendee_api import CONFERENCE, EMPTY, LEAK, Elastic, failure, register

ROOM = "/rooms/topic:eBPF/messages"
MESSAGE = {"conference": CONFERENCE, "text": "Anyone going to the Cilium talk at 11:50?"}
MESSAGE_FIELDS = {"conference", "room", "handle", "text", "at", "expires_at"}


class RoomElastic(Elastic):
    def __init__(self):
        super().__init__()
        self.messages = {}
        self.client.mget.return_value = {"docs": []}

    def index(self, *, index, id, document, **guard):
        if index != "messages":
            return super().index(index=index, id=id, document=document, **guard)
        assert guard == {"op_type": "create", "refresh": True}
        assert id not in self.messages
        self.messages[id] = document
        return {"result": "created"}


def hit(message_id, handle, text, at):
    return {"_id": message_id, "_source": {"handle": handle, "text": text, "at": at}}


def page(*hits, people=0):
    return EMPTY | {"hits": {"hits": list(hits)}, "aggregations": {"people": {"value": people}}}


@pytest.fixture
def elastic(monkeypatch):
    double = RoomElastic()
    monkeypatch.setattr("backend.attendee.elastic.get_elasticsearch_client", lambda: double.client)
    return double


@pytest.fixture
def client(elastic):
    with TestClient(create_app(Settings())) as test_client:
        yield test_client


def test_rooms_require_authentication(client, elastic):
    assert client.post(ROOM, json=MESSAGE).status_code == 401
    assert client.get(ROOM, params={"conference": CONFERENCE}).status_code == 401
    assert elastic.calls == 0


def test_post_stores_one_message_under_the_token_handle(client, elastic):
    headers = register(client)
    response = client.post(ROOM, json=MESSAGE, headers=headers)
    assert response.status_code == 201
    body = response.json()
    assert body["room"] == "topic:ebpf" and set(body) == {"id", "room", "at"}
    stored = elastic.messages[body["id"]]
    assert set(stored) == MESSAGE_FIELDS
    assert stored["handle"] == "ada" and stored["room"] == "topic:ebpf"
    assert stored["text"] == MESSAGE["text"] and stored["conference"] == CONFERENCE
    assert stored["expires_at"] > stored["at"]


def test_post_cannot_choose_a_handle_or_another_conference(client, elastic):
    headers = register(client)
    assert client.post(ROOM, json=MESSAGE | {"handle": "victim"}, headers=headers).status_code == 422
    assert client.post(ROOM, json=MESSAGE | {"conference": "other"}, headers=headers).status_code == 403
    assert elastic.messages == {}


@pytest.mark.parametrize("text", ["", "   ", "x" * 281, "two\nlines"])
def test_post_rejects_empty_long_or_multiline_text(client, elastic, text):
    headers = register(client)
    assert client.post(ROOM, json=MESSAGE | {"text": text}, headers=headers).status_code == 422
    assert elastic.messages == {}


@pytest.mark.parametrize("room", ["eBPF", "person:ada", "topic:", "topic:" + "x" * 129])
def test_rooms_reject_names_that_are_not_topic_or_talk_rooms(client, elastic, room):
    headers = register(client)
    assert client.post(f"/rooms/{room}/messages", json=MESSAGE, headers=headers).status_code in {404, 422}
    assert elastic.messages == {}


def test_post_does_not_create_a_missing_index(client, elastic):
    headers = register(client)
    elastic.client.indices.exists.return_value = False
    assert client.post(ROOM, json=MESSAGE, headers=headers).status_code == 503
    assert elastic.messages == {}


GENERATED = "cf_0123456789abcdef0123"


def test_read_returns_the_newest_page_oldest_first(client, elastic):
    headers = register(client)
    elastic.client.search.return_value = page(
        hit("m2", GENERATED, "Yes, see you there", "2026-11-09T12:01:00Z"),
        hit("m1", "ada", "Anyone going?", "2026-11-09T12:00:00Z"),
        people=2,
    )
    response = client.get(ROOM, params={"conference": CONFERENCE, "limit": 2}, headers=headers)
    body = response.json()
    assert response.status_code == 200
    assert response.headers["Cache-Control"] == "no-store"
    assert body["room"] == "topic:ebpf" and body["people"] == 2
    assert [(m["id"], m["text"], m["mine"]) for m in body["messages"]] == [
        ("m1", "Anyone going?", True),
        ("m2", "Yes, see you there", False),
    ]
    # Nobody here gave their profile a name, so both appear as guests and no handle is returned.
    mine, other = (m["author"] for m in body["messages"])
    assert mine.startswith("guest-") and other.startswith("guest-") and len(other) == 12 and mine != other
    assert GENERATED not in response.text and "ada" not in response.text and "handle" not in response.text


def test_read_shows_the_name_a_person_gave_their_profile(client, elastic):
    headers = register(client)
    elastic.client.search.return_value = page(
        hit("m2", GENERATED, "Yes, see you there", "2026-11-09T12:01:00Z"),
        hit("m1", "ada", "Anyone going?", "2026-11-09T12:00:00Z"),
        people=2,
    )
    elastic.client.mget.return_value = {
        "docs": [
            {"_id": person_id(CONFERENCE, "ada"), "found": True, "_source": {"display_name": "  Ada Lovelace  "}},
            {"_id": person_id(CONFERENCE, GENERATED), "found": True, "_source": {}},
            {"_id": "someone-else", "found": True, "_source": {"display_name": "Mallory"}},
        ]
    }
    body = client.get(ROOM, params={"conference": CONFERENCE}, headers=headers).json()
    assert [m["author"] for m in body["messages"]][0] == "Ada Lovelace"
    assert body["messages"][1]["author"].startswith("guest-")
    call = elastic.client.mget.call_args.kwargs
    assert call["index"] == "people" and call["source"] == ["display_name"]
    assert sorted(call["ids"]) == sorted([person_id(CONFERENCE, "ada"), person_id(CONFERENCE, GENERATED)])


def test_read_still_works_when_names_cannot_be_read(client, elastic):
    headers = register(client)
    elastic.client.search.return_value = page(hit("m1", "ada", "hello", "2026-11-09T12:00:00Z"), people=1)
    elastic.client.mget.side_effect = failure()
    response = client.get(ROOM, params={"conference": CONFERENCE}, headers=headers)
    assert response.status_code == 200
    assert response.json()["messages"][0]["author"].startswith("guest-")


def test_read_asks_only_for_this_room_and_counts_people_over_the_whole_room(client, elastic):
    headers = register(client)
    params = {"conference": CONFERENCE, "after": "2026-11-09T12:00:00Z"}
    assert client.get("/rooms/topic:EBPF/messages", params=params, headers=headers).status_code == 200
    call = elastic.client.search.call_args.kwargs
    assert call["index"] == "messages" and call["size"] == 50
    assert call["sort"] == [{"at": {"order": "desc", "unmapped_type": "date"}}]
    filters = call["query"]["bool"]["filter"]
    assert {"term": {"room": "topic:ebpf"}} in filters
    assert {"term": {"conference": CONFERENCE}} in filters
    assert call["aggs"] == {"people": {"cardinality": {"field": "handle"}}}
    # The cursor narrows the page only, so the people count still covers the room.
    assert call["post_filter"] == {"range": {"at": {"gt": "2026-11-09T12:00:00+00:00"}}}
    assert "range" not in str(filters[2:])


def test_guest_labels_are_stable_in_a_room_and_differ_between_rooms(client, elastic):
    headers = register(client)
    elastic.client.search.return_value = page(hit("m1", GENERATED, "hello", "2026-11-09T12:00:00Z"), people=1)
    first = client.get(ROOM, params={"conference": CONFERENCE}, headers=headers).json()["messages"][0]["author"]
    again = client.get(ROOM, params={"conference": CONFERENCE}, headers=headers).json()["messages"][0]["author"]
    other = client.get("/rooms/topic:Wasm/messages", params={"conference": CONFERENCE}, headers=headers)
    assert first == again
    assert other.json()["messages"][0]["author"] != first


def test_read_an_empty_or_missing_room(client, elastic):
    headers = register(client)
    response = client.get("/rooms/talk:talk-42/messages", params={"conference": CONFERENCE}, headers=headers)
    assert response.status_code == 200
    assert response.json() == {"room": "talk:talk-42", "people": 0, "messages": []}


@pytest.mark.parametrize("params", [{}, {"conference": CONFERENCE, "limit": 0}, {"conference": CONFERENCE, "limit": 101}])
def test_read_rejects_invalid_input(client, elastic, params):
    headers = register(client)
    assert client.get(ROOM, params=params, headers=headers).status_code == 422
    assert elastic.client.search.call_count == 0


def test_read_rejects_another_conference(client, elastic):
    headers = register(client)
    assert client.get(ROOM, params={"conference": "other"}, headers=headers).status_code == 403
    assert elastic.client.search.call_count == 0


def test_room_failures_do_not_leak(client, elastic):
    headers = register(client)
    elastic.client.search.side_effect = failure()
    read = client.get(ROOM, params={"conference": CONFERENCE}, headers=headers)
    elastic.client.indices.exists.side_effect = failure()
    write = client.post(ROOM, json=MESSAGE, headers=headers)
    assert read.status_code == 503 and write.status_code == 503
    assert LEAK not in read.text and LEAK not in write.text


def bucket(room, messages, people, latest="2026-11-09T20:00:00.000Z"):
    return {"key": room, "doc_count": messages, "people": {"value": people}, "latest": {"value": 1.0, "value_as_string": latest}}


def busy(*buckets):
    return EMPTY | {"aggregations": {"rooms": {"buckets": list(buckets)}}}


def test_busy_rooms_require_authentication(client, elastic):
    assert client.get("/rooms", params={"conference": CONFERENCE}).status_code == 401
    assert elastic.calls == 0


def test_busy_rooms_are_listed_busiest_first_with_a_session_cue(client, elastic):
    headers = register(client)
    elastic.client.search.return_value = busy(
        bucket("topic:observability", 12, 3),
        bucket("topic:ai inference + agentic", 90, 34),
        bucket("talk:talk-42", 40, 3),
        bucket("person:ada", 5, 5),
    )
    response = client.get("/rooms", params={"conference": CONFERENCE}, headers=headers)
    body = response.json()
    assert response.status_code == 200
    assert response.headers["Cache-Control"] == "no-store"
    assert body["session_threshold"] == 30 and body["window_minutes"] == 60
    assert [(room["room"], room["people"], room["messages"], room["wants_session"]) for room in body["rooms"]] == [
        ("topic:ai inference + agentic", 34, 90, True),
        ("talk:talk-42", 3, 40, False),
        ("topic:observability", 3, 12, False),
    ]
    assert body["rooms"][0] | {"latest": None} == {
        "room": "topic:ai inference + agentic",
        "kind": "topic",
        "name": "ai inference + agentic",
        "people": 34,
        "messages": 90,
        "latest": None,
        "wants_session": True,
    }
    assert "handle" not in response.text and "ada" not in response.text


def test_busy_rooms_count_recent_messages_in_this_conference_only(client, elastic):
    headers = register(client)
    params = {"conference": CONFERENCE, "window_minutes": 30, "session_threshold": 2, "limit": 1}
    elastic.client.search.return_value = busy(bucket("topic:wasm", 4, 2), bucket("topic:ebpf", 9, 1))
    body = client.get("/rooms", params=params, headers=headers).json()
    assert [room["room"] for room in body["rooms"]] == ["topic:wasm"] and body["rooms"][0]["wants_session"] is True
    call = elastic.client.search.call_args.kwargs
    assert call["index"] == "messages" and call["size"] == 0 and "source" not in call
    filters = call["query"]["bool"]["filter"]
    assert {"term": {"conference": CONFERENCE}} in filters
    assert "gte" in filters[-1]["range"]["at"]
    assert call["aggs"]["rooms"]["terms"] == {"field": "room", "size": 200}
    assert call["aggs"]["rooms"]["aggs"]["people"] == {"cardinality": {"field": "handle"}}


@pytest.mark.parametrize(
    "params",
    [{}, {"conference": CONFERENCE, "window_minutes": 1}, {"conference": CONFERENCE, "session_threshold": 1}, {"conference": CONFERENCE, "limit": 51}],
)
def test_busy_rooms_reject_invalid_input(client, elastic, params):
    headers = register(client)
    assert client.get("/rooms", params=params, headers=headers).status_code == 422
    assert elastic.client.search.call_count == 0


def test_busy_rooms_empty_and_failing(client, elastic):
    headers = register(client)
    assert client.get("/rooms", params={"conference": CONFERENCE}, headers=headers).json()["rooms"] == []
    assert client.get("/rooms", params={"conference": "other"}, headers=headers).status_code == 403
    elastic.client.search.side_effect = failure()
    response = client.get("/rooms", params={"conference": CONFERENCE}, headers=headers)
    assert response.status_code == 503 and LEAK not in response.text
