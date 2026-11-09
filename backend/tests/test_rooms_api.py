"""Room chat: post and read messages in a topic or talk room without exposing handles."""

import pytest
from fastapi.testclient import TestClient

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

    def index(self, *, index, id, document, **guard):
        if index != "messages":
            return super().index(index=index, id=id, document=document, **guard)
        assert guard == {"op_type": "create", "refresh": "wait_for"}
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


def test_read_returns_the_newest_page_oldest_first_without_handles(client, elastic):
    headers = register(client)
    elastic.client.search.return_value = page(
        hit("m2", "grace", "Yes, see you there", "2026-11-09T12:01:00Z"),
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
    authors = [m["author"] for m in body["messages"]]
    assert all(author.startswith("guest-") and len(author) == 12 for author in authors)
    assert authors[0] != authors[1]
    assert "ada" not in response.text and "grace" not in response.text and "handle" not in response.text


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


def test_author_labels_are_stable_in_a_room_and_differ_between_rooms(client, elastic):
    headers = register(client)
    elastic.client.search.return_value = page(hit("m1", "grace", "hello", "2026-11-09T12:00:00Z"), people=1)
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
