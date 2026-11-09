import json
import unittest
from datetime import UTC, datetime, timedelta
from pathlib import Path
from unittest.mock import Mock, patch

from elastic_transport import TransportError
from fastapi.testclient import TestClient
from pydantic import ValidationError

from backend.config import Settings
from backend.geospatial import ConversationCheckIn, GeographicSearch, build_presence
from backend.main import create_app

NOW = datetime(2026, 11, 9, 18, 0, tzinfo=UTC)


class CheckInTests(unittest.TestCase):
    def check_in(self, **overrides):
        return ConversationCheckIn(**{
            "location_consent": True, "venue_id": "venue-1",
            "room_id": "room-a", "source": "manual_room", **overrides,
        })

    def test_room_check_in_requires_no_gps(self):
        presence = build_presence(
            self.check_in(), now=NOW, conversation_expires_at=NOW + timedelta(hours=1)
        )
        self.assertNotIn("location", presence)
        self.assertNotIn("location_consent", presence)
        self.assertTrue(presence["shared"])
        self.assertEqual(presence["expires_at"], (NOW + timedelta(minutes=5)).isoformat())

    def test_expiry_is_capped_by_conversation_retention(self):
        end = NOW + timedelta(seconds=30)
        self.assertEqual(build_presence(
            self.check_in(), now=NOW, conversation_expires_at=end
        )["expires_at"], end.isoformat())

    def test_rejects_missing_false_or_coerced_consent(self):
        for consent in (False, None, "true", 1):
            with self.subTest(consent=consent), self.assertRaises(ValidationError):
                self.check_in(location_consent=consent)
        with self.assertRaises(ValidationError):
            ConversationCheckIn(venue_id="v", room_id="r", source="qr")

    def test_device_requires_coordinates_and_accuracy(self):
        with self.assertRaises(ValidationError):
            self.check_in(source="device")
        check_in = self.check_in(
            source="device", location={"lat": 0, "lon": 0}, accuracy_m=12
        )
        self.assertEqual(check_in.location.lat, 0)

    def test_rejects_bad_coordinates_and_accuracy(self):
        for fields in (
            {"location": {"lat": 91, "lon": 0}},
            {"location": {"lat": 0, "lon": -181}},
            {"location": {"lat": float("nan"), "lon": 0}},
            {"accuracy_m": -1}, {"accuracy_m": 20},
        ):
            with self.subTest(fields=fields), self.assertRaises(ValidationError):
                self.check_in(**fields)

    def test_room_check_in_needs_a_room_or_zone(self):
        with self.assertRaises(ValidationError):
            self.check_in(room_id=None)
        self.assertEqual(self.check_in(room_id=None, zone_id="lobby").zone_id, "lobby")

    def test_cannot_set_client_timestamps_or_unknown_fields(self):
        with self.assertRaises(ValidationError):
            self.check_in(expires_at="2099-01-01T00:00:00Z")

    def test_rejects_invalid_server_expiry(self):
        for end in (NOW, NOW - timedelta(seconds=1), NOW.replace(tzinfo=None)):
            with self.subTest(end=end), self.assertRaises(ValueError):
                build_presence(self.check_in(), now=NOW, conversation_expires_at=end)
        for ttl in (0, 901):
            with self.subTest(ttl=ttl), self.assertRaises(ValueError):
                build_presence(self.check_in(), now=NOW,
                               conversation_expires_at=NOW + timedelta(hours=1), ttl_seconds=ttl)

    def test_presence_document_matches_explicit_mapping(self):
        mapping = json.loads((Path(__file__).parents[1] / "mappings" /
                              "conversation-presence.json").read_text())
        fields = mapping["properties"]["presence"]["properties"]
        presence = build_presence(self.check_in(
            zone_id="lobby", floor="2", location={"lat": 40, "lon": -111}, accuracy_m=10
        ), now=NOW, conversation_expires_at=NOW + timedelta(hours=1))
        self.assertEqual(set(presence), set(fields))
        self.assertEqual(fields["location"]["type"], "geo_point")


class SearchTests(unittest.TestCase):
    def setUp(self):
        self.client = self.enterContext(TestClient(create_app(Settings())))
        self.es = Mock()
        self.es.search.return_value = {"hits": {"hits": []}}
        self.mock_client = patch("backend.session_search.get_elasticsearch_client", return_value=self.es)
        self.mock_client.start()
        self.addCleanup(self.mock_client.stop)
        self.env = patch.dict("os.environ", {"ELASTICSEARCH_TEST_DOCUMENT_ID": "synthetic"})
        self.env.start()
        self.addCleanup(self.env.stop)

    def search(self, **parameters):
        return self.client.get("/querysession", params={"topic": "local AI", **parameters})

    def test_existing_search_contract_and_access_restriction(self):
        self.es.search.return_value = {"hits": {"hits": [{
            "_id": "synthetic", "_source": {"conference": "demo", "transcript": "local AI"}
        }]}}
        response = self.search()
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.json(), {"conversations": [{
            "id": "synthetic", "conference": "demo", "transcript": "local AI"
        }]})
        filters = self.es.search.call_args.kwargs["query"]["bool"]["filter"]
        self.assertEqual(filters, [
            {"term": {"consent": True}}, {"ids": {"values": ["synthetic"]}}
        ])

    def test_room_search_requires_shared_unexpired_presence_and_conversation(self):
        response = self.search(conference="demo", venue_id="v", room_id="a", floor="2")
        self.assertEqual(response.status_code, 200)
        query = self.es.search.call_args.kwargs["query"]["bool"]
        for clause in (
            {"term": {"consent": True}}, {"ids": {"values": ["synthetic"]}},
            {"term": {"conference": "demo"}}, {"term": {"presence.shared": True}},
            {"term": {"presence.venue_id": "v"}}, {"term": {"presence.room_id": "a"}},
            {"term": {"presence.floor": "2"}},
            {"range": {"presence.expires_at": {"gt": "now"}}},
            {"range": {"presence.updated_at": {"lte": "now"}}},
            {"range": {"expires_at": {"gt": "now"}}},
        ):
            self.assertIn(clause, query["filter"])
        self.assertEqual(query["must"], [{"match": {"transcript": "local AI"}}])

    def test_radius_query_preserves_coordinate_order_and_units(self):
        response = self.search(conference="demo", lat=0, lon=-111, radius_m=100)
        self.assertEqual(response.status_code, 200)
        filters = self.es.search.call_args.kwargs["query"]["bool"]["filter"]
        self.assertIn({"geo_distance": {
            "distance": "100.0m", "presence.location": {"lat": 0.0, "lon": -111.0},
            "ignore_unmapped": True,
        }}, filters)

    def test_invalid_queries_fail_before_elasticsearch(self):
        for parameters in (
            {"lat": 40}, {"lat": 40, "lon": -111},
            {"lat": 40, "lon": -111, "radius_m": 100},
            {"conference": "demo", "lat": 91, "lon": 0, "radius_m": 10},
            {"conference": "demo", "lat": 0, "lon": 181, "radius_m": 10},
            {"conference": "demo", "lat": 0, "lon": 0, "radius_m": 0},
            {"conference": "demo", "lat": 0, "lon": 0, "radius_m": 10001},
            {"conference": "demo", "lat": "nan", "lon": 0, "radius_m": 10},
            {"conference": "demo", "room_id": "a"},
            {"conference": "demo", "zone_id": "lobby"},
            {"conference": "demo", "floor": "2"},
            {"conference": " ", "venue_id": "v"},
        ):
            with self.subTest(parameters=parameters):
                self.assertEqual(self.search(**parameters).status_code, 422)
        self.es.search.assert_not_called()

    def test_conference_alone_does_not_require_presence(self):
        self.assertEqual(GeographicSearch(conference="demo").filters(), [
            {"term": {"conference": "demo"}}
        ])

    def test_geographic_response_includes_presence(self):
        presence = {"venue_id": "v", "room_id": "a"}
        self.es.search.return_value = {"hits": {"hits": [{
            "_id": "synthetic", "_source": {"presence": presence}
        }]}}
        response = self.search(conference="demo", venue_id="v")
        self.assertEqual(response.json()["conversations"][0]["presence"], presence)

    def test_unconfigured_or_unavailable_database_returns_503(self):
        self.es.search.side_effect = TransportError("unavailable")
        self.assertEqual(self.search().status_code, 503)
        with patch("backend.session_search.get_elasticsearch_client", return_value=None):
            self.assertEqual(self.search().status_code, 503)


if __name__ == "__main__":
    unittest.main()
