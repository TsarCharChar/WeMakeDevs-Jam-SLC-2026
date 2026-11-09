import asyncio
import json
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest
from elastic_transport import ConnectionError
from fastapi.testclient import TestClient

from backend.attendee.auth import person_id
from backend.attendee.locations import LOCATIONS, purge_expired
from backend.config import Settings
from backend.main import create_app
from backend.maintenance import purge_locations_once
from backend.tests.test_attendee_api import LEAK, failure, register
from backend.tests.test_conversation_matches import MATCH, SHARING, MatchElastic, shared_segment

PATH = "/me/location"
UPDATE = {"location_consent": True, "location": {"lat": 40.76081, "lon": -111.89106}, "accuracy_m": 12}
NEAR = MATCH | {"lat": 40.76, "lon": -111.89, "radius_m": 100}
ROOM = MATCH | {"venue_id": "center", "room_id": "room-a"}
MAPPING = Path(__file__).parents[1] / "mappings" / "attendee-locations.json"


@pytest.fixture
def elastic(monkeypatch):
    double = MatchElastic()
    monkeypatch.setattr("backend.attendee.elastic.get_elasticsearch_client", lambda: double.client)
    return double


@pytest.fixture
def client(elastic):
    with TestClient(create_app(Settings())) as test_client:
        yield test_client


def location_of(elastic, handle="ada", conference="cnh"):
    return elastic.locations[person_id(conference, handle)]["_source"]


def bob_is_sharing(client, **changes):
    bob = shared_segment(client, handle="bob")
    assert client.put(PATH, json=UPDATE | changes, headers=bob).status_code == 200
    return bob


def only_match(client, headers, body=MATCH):
    response = client.post("/matches", json=body, headers=headers)
    assert response.status_code == 200
    assert len(response.json()["matches"]) == 1
    return response.json()["matches"][0]


def test_location_update_requires_token(client, elastic):
    assert client.put(PATH, json=UPDATE).status_code == 401
    assert elastic.calls == 0


def test_location_update_stores_only_mapped_fields(client, elastic):
    response = client.put(PATH, json=UPDATE, headers=register(client))
    assert response.status_code == 200
    assert response.headers["Cache-Control"] == "no-store"
    assert response.json()["show_handle"] is False
    stored = location_of(elastic)
    properties = json.loads(MAPPING.read_text())["mappings"]["properties"]
    assert set(stored) == set(properties)
    assert set(stored["presence"]) <= set(properties["presence"]["properties"])
    assert stored["handle"] == "ada" and stored["conference"] == "cnh"
    assert stored["presence"]["shared"] is True and stored["presence"]["source"] == "device"
    assert "location_consent" not in str(stored)


def test_location_expires_within_minutes(client, elastic):
    body = client.put(PATH, json=UPDATE, headers=register(client)).json()
    assert datetime.fromisoformat(body["expires_at"]) <= datetime.now(UTC) + timedelta(minutes=5)


def test_location_updates_keep_no_history(client, elastic):
    headers = register(client)
    client.put(PATH, json=UPDATE, headers=headers)
    client.put(PATH, json=UPDATE | {"location": {"lat": 1, "lon": 2}}, headers=headers)
    assert len(elastic.locations) == 1
    assert location_of(elastic)["presence"]["location"] == {"lat": 1.0, "lon": 2.0}


@pytest.mark.parametrize(
    "changes",
    [
        {"location_consent": False},
        {"location_consent": "true"},
        {"location": None},
        {"accuracy_m": None},
        {"location": {"lat": 91, "lon": 0}},
        {"source": "manual_room", "room_id": "a"},
        {"show_handle": "yes"},
        {"handle": "victim"},
        {"conference": "other"},
        {"expires_at": "2099-01-01T00:00:00Z"},
    ],
)
def test_location_update_rejects_invalid_input(client, elastic, changes):
    assert client.put(PATH, json=UPDATE | changes, headers=register(client)).status_code == 422
    assert not elastic.locations


def test_location_update_requires_explicit_consent(client, elastic):
    body = {key: value for key, value in UPDATE.items() if key != "location_consent"}
    assert client.put(PATH, json=body, headers=register(client)).status_code == 422
    assert not elastic.locations


def test_location_update_does_not_auto_create_index(client, elastic):
    headers = register(client)
    elastic.client.indices.exists.return_value = False
    assert client.put(PATH, json=UPDATE, headers=headers).status_code == 503
    assert not elastic.locations


@pytest.mark.parametrize("problem", [failure(), ConnectionError(LEAK)])
def test_location_update_failure_does_not_leak(client, elastic, problem):
    headers = register(client)
    elastic.client.indices.exists.side_effect = problem
    response = client.put(PATH, json=UPDATE, headers=headers)
    assert response.status_code == 503
    assert LEAK not in response.text


def test_location_delete_requires_token(client, elastic):
    assert client.delete(PATH).status_code == 401
    assert elastic.calls == 0


def test_location_delete_removes_it_and_is_repeatable(client, elastic):
    headers = register(client)
    client.put(PATH, json=UPDATE, headers=headers)
    assert client.delete(PATH, headers=headers).status_code == 204
    assert not elastic.locations
    assert client.delete(PATH, headers=headers).status_code == 204


def test_location_delete_only_affects_the_caller(client, elastic):
    client.put(PATH, json=UPDATE, headers=register(client))
    assert client.delete(PATH, headers=register(client, handle="mallory")).status_code == 204
    assert len(elastic.locations) == 1


def test_location_delete_failure_does_not_leak(client, elastic):
    headers = register(client)
    elastic.client.delete.side_effect = failure()
    response = client.delete(PATH, headers=headers)
    assert response.status_code == 503
    assert LEAK not in response.text


def test_match_shows_rounded_place_without_author_by_default(client, elastic):
    bob_is_sharing(client)
    response = client.post("/matches", json=MATCH, headers=register(client))
    match = response.json()["matches"][0]
    assert match["place"]["lat"] == 40.7608 and match["place"]["lon"] == -111.8911
    assert match["place"]["accuracy_m"] == 12
    assert "handle" not in match and "bob" not in response.text


def test_match_shows_author_only_when_allowed(client, elastic):
    bob_is_sharing(client, show_handle=True)
    assert only_match(client, register(client))["handle"] == "bob"


def test_match_without_location_has_no_place(client, elastic):
    shared_segment(client, handle="bob")
    match = only_match(client, register(client))
    assert "place" not in match and "handle" not in match


def test_expired_location_is_not_shown(client, elastic):
    bob_is_sharing(client, show_handle=True)
    location_of(elastic, "bob")["presence"]["expires_at"] = "2000-01-01T00:00:00+00:00"
    match = only_match(client, register(client))
    assert "place" not in match and "handle" not in match


def test_stopping_location_removes_the_place(client, elastic):
    bob = bob_is_sharing(client)
    client.delete(PATH, headers=bob)
    assert "place" not in only_match(client, register(client))


def test_location_outage_keeps_matches(client, elastic):
    bob_is_sharing(client)
    elastic.client.mget.side_effect = failure()
    assert "place" not in only_match(client, register(client))


def test_location_alone_does_not_expose_unshared_recordings(client, elastic):
    bob = bob_is_sharing(client)
    client.put(SHARING, json={"shared": False}, headers=bob)
    assert client.post("/matches", json=NEAR, headers=register(client)).json() == {"matches": []}


def test_radius_search_finds_nearby_recorders(client, elastic):
    bob_is_sharing(client)
    only_match(client, register(client), NEAR)
    calls = elastic.client.search.call_args_list
    nearby, conversations = calls[0].kwargs, calls[1].kwargs
    assert nearby["index"] == LOCATIONS
    assert {"term": {"conference": "cnh"}} in nearby["query"]["bool"]["filter"]
    assert {"term": {"presence.shared": True}} in nearby["query"]["bool"]["filter"]
    assert nearby["query"]["bool"]["must_not"] == [{"term": {"handle": "ada"}}]
    assert {"geo_distance": {
        "distance": "100.0m", "presence.location": {"lat": 40.76, "lon": -111.89}, "ignore_unmapped": True,
    }} in nearby["query"]["bool"]["filter"]
    filters = conversations["query"]["knn"]["filter"]["bool"]["filter"]
    assert {"terms": {"handle": ["bob"]}} in filters
    for clause in (
        {"term": {"conference": "cnh"}}, {"term": {"visibility": "conference"}},
        {"term": {"consent": True}}, {"term": {"is_final": True}},
        {"range": {"expires_at": {"gt": "now"}}},
    ):
        assert clause in filters


def test_nobody_nearby_skips_conversation_search(client, elastic):
    response = client.post("/matches", json=NEAR, headers=register(client))
    assert response.json() == {"matches": []}
    assert elastic.client.search.call_count == 1


def test_nearby_search_excludes_other_conferences(client, elastic):
    other = shared_segment(client, handle="bob", conference="other")
    client.put(PATH, json=UPDATE, headers=other)
    assert client.post("/matches", json=NEAR, headers=register(client)).json() == {"matches": []}


def test_room_filter_uses_current_location(client, elastic):
    bob_is_sharing(client, venue_id="center", room_id="room-a")
    ada = register(client)
    assert only_match(client, ada, ROOM)["place"]["room_id"] == "room-a"
    wrong_room = ROOM | {"room_id": "room-b"}
    assert client.post("/matches", json=wrong_room, headers=ada).json() == {"matches": []}


def test_ordinary_matches_do_not_need_a_location(client, elastic):
    shared_segment(client, handle="bob")
    ada = register(client)
    assert client.post("/matches", json=NEAR, headers=ada).json() == {"matches": []}
    assert len(client.post("/matches", json=MATCH, headers=ada).json()["matches"]) == 1


def test_minimum_radius_is_accepted(client, elastic):
    body = NEAR | {"radius_m": 50}
    assert client.post("/matches", json=body, headers=register(client)).status_code == 200


def test_purge_deletes_only_expired_locations(elastic):
    purge_expired(elastic.client)
    call = elastic.client.delete_by_query.call_args.kwargs
    assert call["index"] == LOCATIONS
    assert call["query"] == {"range": {"presence.expires_at": {"lte": "now"}}}
    assert call["conflicts"] == "proceed" and call["max_docs"] == 1000


@pytest.mark.parametrize("problem", [failure(), ConnectionError(LEAK)])
def test_purge_failure_is_contained(elastic, problem, caplog):
    elastic.client.delete_by_query.side_effect = problem
    asyncio.run(purge_locations_once(elastic.client))
    assert LEAK not in caplog.text
