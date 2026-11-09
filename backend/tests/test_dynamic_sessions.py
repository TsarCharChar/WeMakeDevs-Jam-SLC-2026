import copy
import json
from collections import defaultdict
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest
from elastic_transport import ConnectionError
from elasticsearch import ConflictError, NotFoundError
from fastapi.testclient import TestClient
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import SimpleSpanProcessor
from opentelemetry.sdk.trace.export.in_memory_span_exporter import InMemorySpanExporter

from backend.config import Settings
from backend.dynamic_sessions import engine, job, topics
from backend.dynamic_sessions.config import DynamicSessionSettings
from backend.dynamic_sessions.engine import run_evaluation
from backend.dynamic_sessions.rooms import acquire_lock, parse_room, slots
from backend.dynamic_sessions.store import INDEX, ROOM, stable_id
from backend.dynamic_sessions.topics import group_topics, normalize_topic
from backend.main import create_app
from backend.tests.test_attendee_api import LEAK, Elastic, error, failure, register

NOW = datetime.now(UTC).replace(microsecond=0)
SETTINGS = DynamicSessionSettings()
ADMIN = "administrator-token-for-tests-32-chars-long"
ADMIN_HEADERS = {"Authorization": "Bearer " + ADMIN}
TOPIC = "Kubernetes Autoscaling"
MAPPING = json.loads(
    (Path(__file__).parents[1] / "mappings" / "dynamic-sessions.json").read_text()
)["mappings"]["properties"]
ALERT_FIELDS = {"conference", "to_handle", "kind", "room", "why", "seen", "at", "expires_at"}


class DynamicElastic(Elastic):
    def __init__(self):
        self.now = NOW
        self.documents = defaultdict(dict)
        self.exists = True
        self.searches = []
        self.failing = set()
        super().__init__()
        self.client.indices.exists.side_effect = lambda index: self.exists
        self.client.search.side_effect = self.search
        self.client.update.side_effect = self.update
        self.client.bulk.side_effect = self.bulk
        self.client.delete.side_effect = self.delete

    def get(self, *, index, id):
        if id not in self.documents[index]:
            raise error(NotFoundError, 404, {"found": False})
        return copy.deepcopy(self.documents[index][id])

    def index(self, *, index, id, document, **guard):
        if index == INDEX:
            assert set(document) <= set(MAPPING)
        old = self.documents[index].get(id)
        if guard.get("op_type") == "create" and old:
            raise error(ConflictError, 409, {})
        if "if_seq_no" in guard and guard["if_seq_no"] != old["_seq_no"]:
            raise error(ConflictError, 409, {})
        self.documents[index][id] = {
            "_id": id,
            "_index": index,
            "_source": copy.deepcopy(document),
            "_seq_no": old["_seq_no"] + 1 if old else 0,
            "_primary_term": 1,
        }
        return {"result": "created"}

    def update(self, *, index, id, doc, if_seq_no, if_primary_term, refresh):
        assert index == INDEX and set(doc) <= set(MAPPING) and refresh == "wait_for" and if_primary_term == 1
        old = self.documents[index][id]
        if if_seq_no != old["_seq_no"]:
            raise error(ConflictError, 409, {})
        old["_source"].update(copy.deepcopy(doc))
        old["_seq_no"] += 1
        return {"result": "updated"}

    def delete(self, *, index, id, refresh):
        if id not in self.documents[index]:
            raise error(NotFoundError, 404, {"found": False})
        del self.documents[index][id]
        return {"result": "deleted"}

    def bulk(self, *, operations, refresh=None):
        items = []
        for action, document in zip(operations[::2], operations[1::2], strict=True):
            kind, meta = next(iter(action.items()))
            if kind == "create" and meta["_id"] in self.documents[meta["_index"]]:
                items.append({"create": {"status": 409}})
                continue
            self.documents[meta["_index"]][meta["_id"]] = {
                "_id": meta["_id"], "_index": meta["_index"], "_source": copy.deepcopy(document),
                "_seq_no": 0, "_primary_term": 1,
            }
            items.append({kind: {"status": 201}})
        return {"errors": False, "items": items}

    def to_time(self, value):
        return self.now if value == "now" else datetime.fromisoformat(value)

    def matches(self, source, clause):
        kind, body = next(iter(clause.items()))
        if kind == "bool":
            optional = body.get("should", [])
            return (
                all(self.matches(source, item) for item in body.get("filter", []))
                and all(self.matches(source, item) for item in body.get("must", []))
                and not any(self.matches(source, item) for item in body.get("must_not", []))
                and (not optional or any(self.matches(source, item) for item in optional))
            )
        if kind == "exists":
            return body["field"] in source
        field, value = next(iter(body.items()))
        stored = source.get(field)
        if kind == "range":
            if stored is None:
                return False
            moment = self.to_time(stored)
            comparisons = {
                "gt": moment.__gt__, "gte": moment.__ge__, "lt": moment.__lt__, "lte": moment.__le__,
            }
            return all(comparisons[operator](self.to_time(bound)) for operator, bound in value.items())
        stored_values = stored if isinstance(stored, list) else [stored]
        wanted = value if kind == "terms" else [value]
        return any(item in wanted for item in stored_values)

    def search(self, *, index, query=None, size=10, sort=None, source=None, aggregations=None, **options):
        assert options["allow_partial_search_results"] is False
        self.searches.append(index)
        if index in self.failing:
            raise failure()
        found = [
            copy.deepcopy(doc)
            for name in index.split(",")
            for doc in self.documents[name].values()
            if query is None or self.matches(doc["_source"], query)
        ]
        response = {
            "timed_out": False,
            "_shards": {"failed": 0},
            "hits": {"total": {"value": len(found), "relation": "eq"}, "hits": []},
        }
        if aggregations:
            response["aggregations"] = self.aggregate(aggregations, found)
        for clause in reversed(sort or []):
            field, order = next(iter(clause.items()))
            found.sort(key=lambda doc: doc["_source"].get(field, ""), reverse=order["order"] == "desc")
        hits = found[:size]
        if source is not None:
            for hit in hits:
                hit["_source"] = {key: hit["_source"][key] for key in source if key in hit["_source"]}
        for hit in hits:
            hit["_score"] = None
        response["hits"]["hits"] = hits
        return response

    def aggregate(self, aggregations, found):
        name, body = next(iter(aggregations.items()))
        if "terms" in body:
            handles = sorted({doc["_source"][body["terms"]["field"]] for doc in found})
            return {name: {"buckets": [{"key": handle, "doc_count": 1} for handle in handles]}}
        composite = body["composite"]
        fields = [next(iter(item.items()))[0] for item in composite["sources"]]
        rows = set()
        for doc in found:
            source = doc["_source"]
            for topic in source["topics"]:
                rows.add((source["conference"], topic, source["handle"]))
        ordered = sorted(rows)
        if "after" in composite:
            after = tuple(composite["after"][field] for field in fields)
            ordered = [row for row in ordered if row > after]
        page = ordered[: composite["size"]]
        result = {"buckets": [{"key": dict(zip(fields, row, strict=True)), "doc_count": 1} for row in page]}
        if page:
            result["after_key"] = dict(zip(fields, page[-1], strict=True))
        return {name: result}

    def add(self, index, doc_id, document):
        self.documents[index][doc_id] = {
            "_id": doc_id, "_index": index, "_source": document, "_seq_no": 0, "_primary_term": 1,
        }

    def moment(self, handle, topics_=(TOPIC,), conference="cnh", at=None, expires=None, number=0):
        self.add("moments", f"{conference}-{handle}-{number}-{topics_[0]}", {
            "conference": conference,
            "handle": handle,
            "source": "notes",
            "gist": "Synthetic note.",
            "topics": list(topics_),
            "at": (at or self.now - timedelta(minutes=5)).isoformat(),
            "expires_at": (expires or self.now + timedelta(hours=2)).isoformat(),
        })

    def discussing(self, count, conference="cnh", topic=TOPIC, prefix="user"):
        for number in range(count):
            self.moment(f"{prefix}-{number}", (topic,), conference)

    def person(self, handle, conference="cnh", topics_=(), expires=None):
        self.add("people", f"{conference}-{handle}", {
            "conference": conference,
            "handle": handle,
            "topics": list(topics_),
            "expires_at": (expires or self.now + timedelta(days=1)).isoformat(),
        })

    def population(self, count, conference="cnh"):
        for number in range(count):
            self.person(f"member-{number}", conference)

    def room(self, room_id="room-a", name="Dynamic Room A", conference="cnh", capacity=200, **changes):
        document = {
            "record_type": ROOM,
            "conference": conference,
            "room_id": room_id,
            "room": name,
            "capacity": capacity,
            "designated": True,
            "auto_schedule_authorized": True,
            "timezone": "America/Denver",
            "available_windows": [{
                "start": (self.now - timedelta(hours=1)).isoformat(),
                "end": (self.now + timedelta(hours=8)).isoformat(),
            }],
            "accessibility": "Step-free access",
            "demo": True,
            **changes,
        }
        self.add(INDEX, f"room-{conference}-{room_id}", document)

    def sessions(self, status=None):
        records = [doc["_source"] for doc in self.documents[INDEX].values() if doc["_source"]["record_type"] == "session"]
        return [record for record in records if status is None or record["status"] == status]

    def alerts(self):
        return [doc["_source"] for doc in self.documents["alerts"].values()]


@pytest.fixture
def elastic(monkeypatch):
    double = DynamicElastic()
    monkeypatch.setattr("backend.attendee.elastic.get_elasticsearch_client", lambda: double.client)
    monkeypatch.setattr("backend.dynamic_sessions.job.get_elasticsearch_client", lambda: double.client)
    monkeypatch.setenv("DYNAMIC_SESSIONS_ADMIN_TOKEN", ADMIN)
    return double


@pytest.fixture
def client(elastic):
    with TestClient(create_app(Settings())) as test_client:
        yield test_client


def run(elastic, settings=SETTINGS, now=None, **options):
    return run_evaluation(elastic.client, settings, now=now or elastic.now, **options)


def decisions(summary, conference="cnh"):
    return summary["conferences"].get(conference, {}).get("decisions", [])


def test_five_percent_of_attendees_triggers_a_session(elastic):
    elastic.population(100)
    elastic.room()
    elastic.discussing(5)
    summary = run(elastic)
    decision = decisions(summary)[0]
    assert decision["trigger"] == "percentage" and decision["decision"] == "scheduled"
    assert decision["unique_attendees"] == 5 and decision["attendee_percentage"] == 5.0
    assert summary["conferences"]["cnh"]["eligible_attendees"] == 100


def test_below_five_percent_does_not_trigger(elastic):
    elastic.population(100)
    elastic.room()
    elastic.discussing(4)
    assert decisions(run(elastic)) == []


def test_fifty_unique_attendees_triggers_regardless_of_percentage(elastic):
    elastic.population(5000)
    elastic.room()
    elastic.discussing(50)
    decision = decisions(run(elastic))[0]
    assert decision["trigger"] == "absolute" and decision["attendee_percentage"] == 1.0


def test_forty_nine_of_a_large_conference_does_not_trigger(elastic):
    elastic.population(5000)
    elastic.room()
    elastic.discussing(49)
    assert decisions(run(elastic)) == []


def test_repeated_messages_from_one_person_count_once(elastic):
    elastic.population(4)
    elastic.room()
    for number in range(20):
        elastic.moment("chatty", number=number)
    assert decisions(run(elastic)) == []


def test_minimum_unique_people_protects_small_conferences(elastic):
    elastic.population(10)
    elastic.room()
    elastic.discussing(2)
    assert decisions(run(elastic)) == []
    elastic.discussing(3)
    assert decisions(run(elastic))[0]["unique_attendees"] == 3


def test_person_using_two_spellings_counts_once(elastic):
    elastic.population(10)
    elastic.moment("same", (TOPIC,), number=1)
    elastic.moment("same", ("kubernetes auto-scaling",), number=2)
    elastic.moment("other", ("K8s autoscaling",), number=3)
    assert decisions(run(elastic)) == []


@pytest.mark.parametrize(
    "label",
    ["Kubernetes Autoscaling", "kubernetes autoscaling", "KUBERNETES  AUTO-SCALING", "k8s auto_scaling", "kuberentes autoscaling"],
)
def test_similar_labels_group_together(label):
    grouped = group_topics([("Kubernetes Autoscaling", "a"), (label, "b")])
    assert len(grouped) == 1 and grouped[0].handles == {"a", "b"}


@pytest.mark.parametrize(
    ("first", "second"),
    [("CPU Scheduling", "GPU Scheduling"), ("Kubernetes Security", "Kubernetes Autoscaling"), ("eBPF", "Kubernetes")],
)
def test_different_topics_stay_separate(first, second):
    assert len(group_topics([(first, "a"), (second, "b")])) == 2


def test_label_prefers_most_common_and_titles_lowercase():
    grouped = group_topics([("kubernetes autoscaling", "a"), ("kubernetes autoscaling", "b"), ("K8s Autoscaling", "c")])
    assert grouped[0].label == "Kubernetes Autoscaling"
    assert normalize_topic(" K8S, auto-scaling! ") == "kubernetes autoscaling"


def test_mixed_spellings_trigger_one_session(elastic):
    elastic.population(50)
    elastic.room()
    for number, topic in enumerate([TOPIC, "kubernetes auto-scaling", "K8s autoscaling"]):
        elastic.moment(f"user-{number}", (topic,))
    run(elastic)
    assert len(elastic.sessions()) == 1
    assert elastic.sessions()[0]["attendee_count"] == 3


def test_composite_pagination_counts_everyone(elastic, monkeypatch):
    monkeypatch.setattr(topics, "COMPOSITE_PAGE", 7)
    elastic.room()
    elastic.discussing(50)
    summary = run(elastic)
    assert decisions(summary)[0]["unique_attendees"] == 50
    assert summary["truncated"] is False


def test_old_and_expired_moments_are_ignored(elastic):
    elastic.population(10)
    elastic.room()
    for number in range(3):
        elastic.moment(f"old-{number}", at=elastic.now - timedelta(minutes=31))
        elastic.moment(f"gone-{number}", expires=elastic.now - timedelta(seconds=1))
    assert decisions(run(elastic)) == []


def test_private_transcripts_are_never_read(elastic):
    elastic.population(10)
    elastic.room()
    elastic.discussing(5)
    run(elastic)
    assert not any("conversations" in index for index in elastic.searches)


def test_summary_contains_no_attendee_data(elastic):
    elastic.population(10)
    elastic.room()
    elastic.discussing(5, prefix="secret-handle")
    summary = json.dumps(run(elastic))
    assert "secret-handle" not in summary and "Synthetic note" not in summary


def test_scheduled_session_shape(elastic):
    elastic.population(100)
    elastic.room()
    elastic.discussing(10)
    run(elastic)
    session = elastic.sessions("scheduled")[0]
    assert session["title"] == "Kubernetes Autoscaling Discussion"
    assert session["room"] == "Dynamic Room A" and session["capacity"] == 200
    assert session["description"] == "A spontaneous discussion organized around common attendee interests"
    assert session["attendee_percentage"] == 10.0
    start, end = datetime.fromisoformat(session["start"]), datetime.fromisoformat(session["end"])
    assert end - start == timedelta(minutes=30)
    assert start >= NOW + timedelta(minutes=15) and start.minute % 30 == 0
    assert start.utcoffset() in (timedelta(hours=-6), timedelta(hours=-7))
    assert session["timezone"] == "America/Denver"


def test_no_room_keeps_a_pending_proposal(elastic):
    elastic.population(10)
    elastic.discussing(5)
    decision = decisions(run(elastic))[0]
    assert decision["decision"] == "pending" and decision["reason"] == "no_designated_room"
    assert elastic.sessions()[0]["status"] == "proposed"
    assert elastic.sessions()[0]["pending_reason"] == "no_designated_room"
    assert "start" not in elastic.sessions()[0]
    assert elastic.alerts() == []


@pytest.mark.parametrize(
    "changes",
    [{"designated": False}, {"auto_schedule_authorized": False}, {"timezone": "Not/AZone"}, {"capacity": "large"}],
)
def test_ineligible_rooms_are_not_used(elastic, changes):
    elastic.population(10)
    elastic.room(**changes)
    elastic.discussing(5)
    assert decisions(run(elastic))[0]["reason"] == "no_designated_room"


def test_room_too_small_stays_pending(elastic):
    elastic.population(100)
    elastic.room(capacity=4)
    elastic.discussing(5)
    assert decisions(run(elastic))[0]["reason"] == "insufficient_capacity"


def test_smallest_room_that_fits_is_preferred(elastic):
    elastic.population(100)
    elastic.room("big", "Big Room", capacity=500)
    elastic.room("small", "Small Room", capacity=10)
    elastic.discussing(5)
    run(elastic)
    assert elastic.sessions()[0]["room"] == "Small Room"


def test_room_with_no_open_window_stays_pending(elastic):
    elastic.population(10)
    elastic.room(available_windows=[{
        "start": (elastic.now - timedelta(hours=3)).isoformat(),
        "end": (elastic.now - timedelta(hours=2)).isoformat(),
    }])
    elastic.discussing(5)
    assert decisions(run(elastic))[0]["reason"] == "no_available_slot"


def first_slot(elastic, room_name="Dynamic Room A"):
    room = parse_room(next(
        doc["_source"] for doc in elastic.documents[INDEX].values() if doc["_source"].get("room") == room_name
    ))
    return next(iter(slots(room, elastic.now, SETTINGS)))


def test_talk_conflict_moves_to_the_next_slot(elastic):
    elastic.population(10)
    elastic.room()
    elastic.discussing(5)
    start, end = first_slot(elastic)
    elastic.add("talks", "t1", {
        "conference": "cnh", "room": "Dynamic Room A", "start": start.isoformat(), "end": end.isoformat(),
    })
    run(elastic)
    assert datetime.fromisoformat(elastic.sessions()[0]["start"]) == end


def test_every_slot_taken_stays_pending(elastic):
    elastic.population(10)
    elastic.room()
    elastic.discussing(5)
    elastic.add("talks", "t1", {
        "conference": "cnh",
        "room": "room-a",
        "start": elastic.now.isoformat(),
        "end": (elastic.now + timedelta(hours=8)).isoformat(),
    })
    assert decisions(run(elastic))[0]["reason"] == "no_available_slot"


def test_talk_in_another_conference_is_not_a_conflict(elastic):
    elastic.population(10)
    elastic.room()
    elastic.discussing(5)
    start, end = first_slot(elastic)
    elastic.add("talks", "t1", {
        "conference": "other", "room": "Dynamic Room A", "start": start.isoformat(), "end": end.isoformat(),
    })
    run(elastic)
    assert datetime.fromisoformat(elastic.sessions()[0]["start"]) == start


def test_two_topics_do_not_double_book_one_room(elastic):
    elastic.population(100)
    elastic.room()
    elastic.discussing(10)
    elastic.discussing(8, topic="eBPF Tracing", prefix="ebpf")
    run(elastic)
    starts = [session["start"] for session in elastic.sessions("scheduled")]
    assert len(starts) == 2 and len(set(starts)) == 2


def test_lock_held_by_another_session_is_skipped(elastic):
    elastic.population(10)
    elastic.room()
    elastic.discussing(5)
    start, end = first_slot(elastic)
    room = parse_room(next(
        doc["_source"] for doc in elastic.documents[INDEX].values() if doc["_source"].get("room_id") == "room-a"
    ))
    assert acquire_lock(elastic.client, "cnh", room, start, end, "other-session", elastic.now) == "created"
    run(elastic)
    assert datetime.fromisoformat(elastic.sessions()[0]["start"]) == end


def test_lock_retry_recognizes_its_own_session(elastic):
    elastic.room()
    start, end = first_slot(elastic)
    room = parse_room(next(
        doc["_source"] for doc in elastic.documents[INDEX].values() if doc["_source"].get("room_id") == "room-a"
    ))
    assert acquire_lock(elastic.client, "cnh", room, start, end, "s1", elastic.now) == "created"
    assert acquire_lock(elastic.client, "cnh", room, start, end, "s1", elastic.now) == "existing"
    assert acquire_lock(elastic.client, "cnh", room, start, end, "s2", elastic.now) is None


def test_duplicate_runs_create_one_session(elastic):
    elastic.population(10)
    elastic.room()
    elastic.discussing(5)
    run(elastic)
    second = decisions(run(elastic))[0]
    assert second["decision"] == "cooldown"
    assert len(elastic.sessions()) == 1


def test_concurrent_runs_that_both_miss_the_search_create_one_session(elastic, monkeypatch):
    monkeypatch.setattr(engine, "find_recent", lambda *args: None)
    elastic.population(10)
    elastic.room()
    elastic.discussing(5)
    run(elastic)
    run(elastic)
    assert len(elastic.sessions()) == 1
    locks = [doc for doc in elastic.documents[INDEX].values() if doc["_source"]["record_type"] == "room_lock"]
    assert len(locks) == 1


def test_losing_a_concurrent_update_keeps_the_winners_lock(elastic):
    elastic.population(10)
    elastic.room()
    elastic.discussing(5)
    original = elastic.update

    def rival_wins(*, index, id, doc, if_seq_no, if_primary_term, refresh):
        if doc.get("status") == "scheduled":
            elastic.client.update.side_effect = original
            original(index=index, id=id, doc=doc, if_seq_no=if_seq_no, if_primary_term=1, refresh=refresh)
            raise error(ConflictError, 409, {})
        return original(index=index, id=id, doc=doc, if_seq_no=if_seq_no, if_primary_term=1, refresh=refresh)

    elastic.client.update.side_effect = rival_wins
    decision = decisions(run(elastic))[0]
    assert decision["decision"] == "already_scheduled"
    records = [doc["_source"]["record_type"] for doc in elastic.documents[INDEX].values()]
    assert records.count("room_lock") == 1


def test_losing_a_concurrent_update_releases_its_different_slot_lock(elastic):
    elastic.population(10)
    elastic.room()
    elastic.room("room-b", "Dynamic Room B")
    elastic.discussing(5)
    room_b = parse_room(elastic.documents[INDEX]["room-cnh-room-b"]["_source"])
    assert room_b is not None
    original = elastic.update

    def rival_wins_elsewhere(*, index, id, doc, if_seq_no, if_primary_term, refresh):
        if doc.get("status") == "scheduled":
            elastic.client.update.side_effect = original
            start, end = datetime.fromisoformat(doc["start"]), datetime.fromisoformat(doc["end"])
            assert acquire_lock(elastic.client, "cnh", room_b, start, end, id, elastic.now) == "created"
            winner_doc = {**doc, "room_id": room_b.room_id, "room": room_b.name}
            original(index=index, id=id, doc=winner_doc, if_seq_no=if_seq_no, if_primary_term=1, refresh=refresh)
            raise error(ConflictError, 409, {})
        return original(index=index, id=id, doc=doc, if_seq_no=if_seq_no, if_primary_term=1, refresh=refresh)

    elastic.client.update.side_effect = rival_wins_elsewhere
    decision = decisions(run(elastic))[0]
    assert decision["decision"] == "already_scheduled"
    locks = [doc["_source"] for doc in elastic.documents[INDEX].values() if doc["_source"]["record_type"] == "room_lock"]
    assert len(locks) == 1 and locks[0]["room_id"] == room_b.room_id


def test_pending_proposal_is_scheduled_when_a_room_appears(elastic):
    elastic.population(10)
    elastic.discussing(5)
    run(elastic)
    elastic.room()
    assert decisions(run(elastic))[0]["decision"] == "scheduled"
    assert len(elastic.sessions()) == 1
    assert elastic.sessions()[0]["pending_reason"] is None


def test_cooldown_prevents_repeat_sessions(elastic):
    elastic.population(10)
    elastic.room()
    elastic.discussing(5)
    run(elastic)
    elastic.now += timedelta(minutes=60)
    elastic.discussing(5, prefix="later")
    assert decisions(run(elastic))[0]["decision"] == "cooldown"
    assert len(elastic.sessions()) == 1


def test_topic_can_return_after_cooldown_and_session_end(elastic):
    elastic.population(10)
    elastic.room(available_windows=[{
        "start": (elastic.now - timedelta(hours=1)).isoformat(),
        "end": (elastic.now + timedelta(hours=24)).isoformat(),
    }])
    elastic.discussing(5)
    run(elastic)
    elastic.now += timedelta(minutes=SETTINGS.cooldown_minutes + 60)
    elastic.discussing(5, prefix="later")
    assert decisions(run(elastic))[0]["decision"] == "scheduled"
    assert len(elastic.sessions("scheduled")) == 2


def test_active_session_blocks_a_repeat_even_after_cooldown(elastic):
    settings = DynamicSessionSettings(cooldown_minutes=1, lead_minutes=120, horizon_minutes=300)
    elastic.population(10)
    elastic.room()
    elastic.discussing(5)
    run(elastic, settings)
    elastic.now += timedelta(minutes=10)
    elastic.discussing(5, prefix="later")
    assert decisions(run(elastic, settings))[0]["decision"] == "cooldown"


@pytest.mark.parametrize("total", [None, {"value": 0, "relation": "eq"}, {"value": "many", "relation": "eq"}, {"value": 500, "relation": "gte"}])
def test_invalid_denominator_only_allows_the_absolute_rule(elastic, total):
    original = elastic.search

    def with_total(**kwargs):
        response = original(**kwargs)
        if kwargs["index"] == "people":
            response["hits"]["total"] = total
        return response

    elastic.client.search.side_effect = with_total
    elastic.room()
    elastic.discussing(10)
    summary = run(elastic)
    assert decisions(summary) == []
    assert summary["conferences"]["cnh"]["denominator"] == "unavailable"
    elastic.discussing(50, prefix="many")
    decision = decisions(run(elastic))[0]
    assert decision["trigger"] == "absolute" and decision["attendee_percentage"] is None


def test_denominator_failure_falls_back_to_absolute(elastic):
    elastic.failing.add("people")
    elastic.room()
    elastic.discussing(50)
    summary = run(elastic)
    assert summary["conferences"]["cnh"]["eligible_attendees"] is None
    assert decisions(summary)[0]["trigger"] == "absolute"


def test_denominator_excludes_expired_and_other_conferences(elastic):
    elastic.population(100, "other")
    for number in range(100):
        elastic.person(f"expired-{number}", expires=elastic.now - timedelta(seconds=1))
    elastic.population(10)
    elastic.room()
    elastic.discussing(3)
    assert run(elastic)["conferences"]["cnh"]["eligible_attendees"] == 10


def test_elasticsearch_failure_reading_moments_raises(elastic):
    elastic.failing.add("moments")
    with pytest.raises(Exception) as caught:
        run(elastic)
    assert caught.value.status == 503 and LEAK not in str(caught.value)


def test_room_lookup_failure_writes_no_schedule(elastic):
    elastic.population(10)
    elastic.room()
    elastic.discussing(5)
    elastic.failing.add("talks")
    summary = run(elastic)
    assert summary["status"] == "partial" and summary["errors"] == ["cnh"]
    assert elastic.sessions("scheduled") == []


def test_one_failing_conference_does_not_block_another(elastic):
    elastic.population(10)
    elastic.population(10, "other")
    elastic.room()
    elastic.room(conference="other")
    elastic.discussing(5)
    elastic.discussing(5, "other")
    original = elastic.search

    def fail_one(**kwargs):
        query = str(kwargs.get("query"))
        if kwargs["index"] == "talks" and "'conference': 'cnh'" in query:
            raise failure()
        return original(**kwargs)

    elastic.client.search.side_effect = fail_one
    summary = run(elastic)
    assert summary["errors"] == ["cnh"]
    assert decisions(summary, "other")[0]["decision"] == "scheduled"


def test_conferences_stay_isolated(elastic):
    elastic.population(10)
    elastic.population(10, "other")
    elastic.room()
    elastic.discussing(3)
    elastic.discussing(2, "other")
    summary = run(elastic)
    assert decisions(summary, "other") == []
    assert [session["conference"] for session in elastic.sessions()] == ["cnh"]


def test_rooms_from_another_conference_are_not_used(elastic):
    elastic.population(10)
    elastic.room(conference="other")
    elastic.discussing(5)
    assert decisions(run(elastic))[0]["reason"] == "no_designated_room"


def test_same_handle_in_two_conferences_is_counted_separately(elastic):
    elastic.population(10)
    elastic.population(10, "other")
    for number in range(2):
        elastic.moment(f"shared-{number}")
        elastic.moment(f"shared-{number}", conference="other")
    assert decisions(run(elastic)) == [] and decisions(run(elastic), "other") == []


def test_max_new_sessions_per_run(elastic):
    settings = DynamicSessionSettings(max_new_per_run=1)
    elastic.population(100)
    elastic.room()
    elastic.discussing(10)
    elastic.discussing(8, topic="eBPF Tracing", prefix="ebpf")
    outcomes = [decision["decision"] for decision in decisions(run(elastic, settings))]
    assert outcomes == ["scheduled", "deferred"]


def test_dry_run_writes_nothing(elastic):
    elastic.population(10)
    elastic.room()
    elastic.discussing(5)
    assert decisions(run(elastic, dry_run=True))[0]["decision"] == "would_propose"
    assert elastic.sessions() == []


def test_not_provisioned_does_not_write(elastic):
    elastic.exists = False
    elastic.discussing(50)
    assert run(elastic)["status"] == "not_provisioned"
    elastic.client.index.assert_not_called()


def test_alerts_go_to_opted_in_attendees_once(elastic):
    elastic.population(10)
    elastic.person("interested", topics_=("kubernetes auto-scaling",))
    elastic.person("author-1")
    elastic.person("expired", topics_=(TOPIC,), expires=elastic.now - timedelta(seconds=1))
    elastic.room()
    elastic.moment("author-1")
    elastic.moment("no-profile")
    elastic.moment("author-2", ("kubernetes auto-scaling",))
    run(elastic)
    assert elastic.sessions()[0]["topics"] == [TOPIC, "kubernetes auto-scaling"]
    alerts = elastic.alerts()
    assert sorted(alert["to_handle"] for alert in alerts) == ["author-1", "interested"]
    assert all(set(alert) == ALERT_FIELDS for alert in alerts)
    assert alerts[0]["kind"] == "dynamic_session" and alerts[0]["seen"] is False
    assert "Kubernetes Autoscaling Discussion" in alerts[0]["why"] and "Dynamic Room A" in alerts[0]["why"]
    assert elastic.sessions()[0]["alerts_sent"] is True
    run(elastic)
    assert len(elastic.alerts()) == 2


def test_pending_proposal_sends_no_alerts(elastic):
    elastic.person("interested", topics_=(TOPIC,))
    elastic.discussing(3)
    run(elastic)
    assert elastic.alerts() == []


def test_alert_failure_keeps_the_session_and_retries(elastic):
    elastic.population(10)
    elastic.person("interested", topics_=(TOPIC,))
    elastic.room()
    elastic.discussing(5)
    good = elastic.client.bulk.side_effect
    elastic.client.bulk.side_effect = failure()
    assert decisions(run(elastic))[0]["alerts"] == "failed"
    assert elastic.sessions()[0]["status"] == "scheduled" and elastic.sessions()[0]["alerts_sent"] is False
    elastic.client.bulk.side_effect = good
    assert decisions(run(elastic))[0]["alerts"] == "sent:1"
    assert elastic.sessions()[0]["alerts_sent"] is True


def test_rejected_alert_item_is_retried(elastic):
    elastic.population(10)
    elastic.person("interested", topics_=(TOPIC,))
    elastic.room()
    elastic.discussing(5)
    elastic.client.bulk.side_effect = lambda **kwargs: {"items": [{"create": {"status": 429}}]}
    assert decisions(run(elastic))[0]["alerts"] == "failed"


def test_demo_scenario_with_fifty_five_attendees(elastic):
    assert job.seed_demo(elastic.client, "demo-kubecon", elastic.now)["moments"] == 55
    summary = run(elastic)
    decision = decisions(summary, "demo-kubecon")[0]
    assert decision["trigger"] == "absolute" and decision["unique_attendees"] == 55
    session = elastic.sessions("scheduled")[0]
    assert session["title"] == "Kubernetes Autoscaling Discussion"
    assert session["room"] == "Dynamic Room A" and session["demo"] is True


def test_job_run_prints_summary_and_succeeds(elastic, capsys):
    elastic.population(10)
    elastic.room()
    elastic.discussing(5)
    assert job.main(["run"]) == 0
    assert json.loads(capsys.readouterr().out)["status"] == "ok"


def test_job_not_provisioned_exits_cleanly(elastic, capsys):
    elastic.exists = False
    assert job.main(["run"]) == 0
    assert json.loads(capsys.readouterr().out)["status"] == "not_provisioned"


def test_job_elasticsearch_failure_exits_nonzero_without_leaking(elastic, capsys):
    elastic.client.indices.exists.side_effect = ConnectionError(LEAK)
    assert job.main(["run"]) == 1
    assert LEAK not in capsys.readouterr().out


def test_job_partial_run_exits_nonzero(elastic, capsys):
    elastic.population(10)
    elastic.room()
    elastic.discussing(5)
    elastic.failing.add("talks")
    assert job.main(["run"]) == 1
    assert json.loads(capsys.readouterr().out)["errors"] == ["cnh"]


def test_job_without_credentials_exits_nonzero(monkeypatch, capsys):
    monkeypatch.setattr("backend.dynamic_sessions.job.get_elasticsearch_client", lambda: None)
    assert job.main(["run"]) == 1


def test_job_invalid_settings_exit_nonzero(elastic, monkeypatch, capsys):
    monkeypatch.setenv("DYNAMIC_SESSIONS_WINDOW_MINUTES", "soon")
    assert job.main(["run"]) == 1


def test_seed_demo_refuses_real_conferences_by_default(elastic):
    with pytest.raises(SystemExit):
        job.main(["seed-demo", "--conference", "cnh"])
    assert not elastic.documents["moments"]


def test_settings_read_environment(monkeypatch):
    monkeypatch.setenv("DYNAMIC_SESSIONS_WINDOW_MINUTES", "45")
    monkeypatch.setenv("DYNAMIC_SESSIONS_PERCENT_THRESHOLD", "7.5")
    settings = DynamicSessionSettings.from_env()
    assert settings.window_minutes == 45 and settings.percent_threshold == 7.5
    assert "admin_token" not in repr(settings) or ADMIN not in repr(settings)


@pytest.mark.parametrize(("name", "value"), [
    ("DYNAMIC_SESSIONS_WINDOW_MINUTES", "0"),
    ("DYNAMIC_SESSIONS_ABSOLUTE_THRESHOLD", "many"),
    ("DYNAMIC_SESSIONS_PERCENT_THRESHOLD", "nan"),
])
def test_settings_reject_invalid_values(monkeypatch, name, value):
    monkeypatch.setenv(name, value)
    with pytest.raises(ValueError):
        DynamicSessionSettings.from_env()


def scheduled_session(elastic):
    elastic.population(10)
    elastic.room()
    elastic.discussing(5)
    run(elastic)
    return elastic.sessions("scheduled")[0]


def test_list_requires_attendee_token(client, elastic):
    assert client.get("/dynamic-sessions", params={"conference": "cnh"}).status_code == 401


def test_list_rejects_other_conference(client, elastic):
    response = client.get("/dynamic-sessions", params={"conference": "other"}, headers=register(client))
    assert response.status_code == 403


def test_list_returns_stable_public_format(client, elastic):
    session = scheduled_session(elastic)
    response = client.get("/dynamic-sessions", params={"conference": "cnh"}, headers=register(client))
    assert response.status_code == 200
    item = response.json()["sessions"][0]
    assert item["id"] == session["id"] and item["type"] == "dynamic" and item["status"] == "scheduled"
    assert item["title"] == "Kubernetes Autoscaling Discussion" and item["room"] == "Dynamic Room A"
    assert not {"record_type", "topic_key", "alerts_sent", "pending_reason", "user-0"} & set(item)
    assert "user-0" not in response.text


def test_list_hides_proposals(client, elastic):
    elastic.population(10)
    elastic.discussing(5)
    run(elastic)
    response = client.get("/dynamic-sessions", params={"conference": "cnh"}, headers=register(client))
    assert response.json() == {"sessions": []}


def test_list_upcoming_filter(client, elastic):
    session = scheduled_session(elastic)
    next(doc for doc in elastic.documents[INDEX].values() if doc["_source"].get("id") == session["id"])[
        "_source"
    ]["end"] = (elastic.now - timedelta(minutes=1)).isoformat()
    headers = register(client)
    assert client.get("/dynamic-sessions", params={"conference": "cnh"}, headers=headers).json() == {"sessions": []}
    everything = client.get("/dynamic-sessions", params={"conference": "cnh", "upcoming": False}, headers=headers)
    assert len(everything.json()["sessions"]) == 1


def test_list_empty_and_failure(client, elastic):
    headers = register(client)
    assert client.get("/dynamic-sessions", params={"conference": "cnh"}, headers=headers).json() == {"sessions": []}
    elastic.failing.add(INDEX)
    response = client.get("/dynamic-sessions", params={"conference": "cnh"}, headers=headers)
    assert response.status_code == 503 and LEAK not in response.text


def test_get_session_details(client, elastic):
    session = scheduled_session(elastic)
    response = client.get(f"/dynamic-sessions/{session['id']}", headers=register(client))
    assert response.status_code == 200 and response.json()["id"] == session["id"]


def test_get_session_requires_token(client, elastic):
    assert client.get("/dynamic-sessions/ds-1").status_code == 401


@pytest.mark.parametrize("session_id", ["ds-missing", "room-cnh-room-a"])
def test_get_session_missing_or_not_a_session(client, elastic, session_id):
    elastic.room()
    assert client.get(f"/dynamic-sessions/{session_id}", headers=register(client)).status_code == 404


def test_get_session_hides_other_conference_and_proposals(client, elastic):
    session = scheduled_session(elastic)
    other = register(client, conference="other")
    assert client.get(f"/dynamic-sessions/{session['id']}", headers=other).status_code == 404
    next(doc for doc in elastic.documents[INDEX].values() if doc["_source"].get("id") == session["id"])[
        "_source"
    ]["status"] = "proposed"
    assert client.get(f"/dynamic-sessions/{session['id']}", headers=register(client)).status_code == 404


def test_run_requires_administrator(client, elastic):
    assert client.post("/dynamic-sessions/run").status_code == 401
    assert client.post("/dynamic-sessions/run", headers={"Authorization": "Bearer wrong"}).status_code == 401
    assert client.post("/dynamic-sessions/run", headers=register(client)).status_code == 401
    elastic.client.indices.exists.assert_not_called()


def test_run_is_disabled_without_a_strong_token(client, elastic, monkeypatch):
    monkeypatch.setenv("DYNAMIC_SESSIONS_ADMIN_TOKEN", "short")
    assert client.post("/dynamic-sessions/run", headers={"Authorization": "Bearer short"}).status_code == 503


def test_run_creates_session(client, elastic):
    elastic.population(10)
    elastic.room()
    elastic.discussing(5)
    response = client.post("/dynamic-sessions/run", headers=ADMIN_HEADERS, json={"conference": "cnh"})
    assert response.status_code == 200 and response.headers["Cache-Control"] == "no-store"
    assert decisions(response.json())[0]["decision"] == "scheduled"
    assert len(elastic.sessions("scheduled")) == 1


def test_run_scoped_to_one_conference(client, elastic):
    elastic.population(10, "other")
    elastic.room(conference="other")
    elastic.discussing(5, "other")
    response = client.post("/dynamic-sessions/run", headers=ADMIN_HEADERS, json={"conference": "cnh"})
    assert response.json()["conferences"] == {} and elastic.sessions() == []


def test_run_rejects_unknown_fields(client, elastic):
    assert client.post("/dynamic-sessions/run", headers=ADMIN_HEADERS, json={"force": True}).status_code == 422


def test_run_not_provisioned_and_failure(client, elastic):
    elastic.exists = False
    assert client.post("/dynamic-sessions/run", headers=ADMIN_HEADERS).status_code == 503
    elastic.exists = True
    elastic.failing.add("moments")
    response = client.post("/dynamic-sessions/run", headers=ADMIN_HEADERS)
    assert response.status_code == 503 and LEAK not in response.text


def pending_session(elastic):
    elastic.population(10)
    elastic.discussing(5)
    run(elastic)
    return elastic.sessions("proposed")[0]


def test_approve_requires_administrator(client, elastic):
    session = pending_session(elastic)
    url = f"/dynamic-sessions/{session['id']}/approve"
    assert client.post(url, json={"room_id": "room-a"}).status_code == 401
    assert client.post(url, json={"room_id": "room-a"}, headers=register(client)).status_code == 401


def test_approve_can_use_a_room_not_authorized_for_automatic_scheduling(client, elastic):
    session = pending_session(elastic)
    elastic.room(auto_schedule_authorized=False)
    response = client.post(
        f"/dynamic-sessions/{session['id']}/approve", json={"room_id": "room-a"}, headers=ADMIN_HEADERS
    )
    assert response.status_code == 200 and response.json()["status"] == "scheduled"


def test_approve_still_requires_a_designated_room(client, elastic):
    session = pending_session(elastic)
    elastic.room(designated=False)
    response = client.post(
        f"/dynamic-sessions/{session['id']}/approve", json={"room_id": "room-a"}, headers=ADMIN_HEADERS
    )
    assert response.status_code == 409 and "no_designated_room" in response.text


def test_approve_missing_and_already_scheduled(client, elastic):
    headers = ADMIN_HEADERS
    assert client.post("/dynamic-sessions/ds-none/approve", json={"room_id": "r"}, headers=headers).status_code == 404
    session = scheduled_session(elastic)
    response = client.post(f"/dynamic-sessions/{session['id']}/approve", json={"room_id": "room-a"}, headers=headers)
    assert response.status_code == 409


def test_existing_routes_still_work(client, elastic):
    assert client.get("/healthz").json() == {"status": "healthy"}
    assert client.get("/readyz").json()["status"] == "ready"
    assert client.post("/search", json={"conference": "cnh", "interests": "AI"}).status_code == 503


def test_stable_ids_are_scoped():
    assert stable_id("ds", "a", "bc") != stable_id("ds", "ab", "c")


def test_traces_record_decisions_without_attendee_data(elastic, monkeypatch):
    exporter = InMemorySpanExporter()
    provider = TracerProvider()
    provider.add_span_processor(SimpleSpanProcessor(exporter))
    monkeypatch.setattr(engine, "tracer", provider.get_tracer("test"))
    elastic.population(10)
    elastic.room()
    elastic.discussing(5, prefix="secret-handle")
    run(elastic)
    span = next(item for item in exporter.get_finished_spans() if item.name == "dynamic_sessions.run")
    assert span.attributes["dynamic_sessions.status"] == "ok"
    event = next(item for item in span.events if item.name == "dynamic_session.decision")
    assert event.attributes["decision"] == "scheduled" and event.attributes["unique_attendees"] == 5
    recorded = str([dict(item.attributes) for item in span.events])
    assert "secret-handle" not in recorded and "Synthetic note" not in recorded
