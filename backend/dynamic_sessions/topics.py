import math
import re
import unicodedata
from collections import Counter
from collections.abc import Iterable
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from difflib import SequenceMatcher

from elasticsearch import Elasticsearch

from backend.attendee.elastic import MOMENTS, PEOPLE, run_search
from backend.dynamic_sessions.config import DynamicSessionSettings
from backend.vector_store import StoreError

COMPOSITE_PAGE = 1000
MAX_PAGES = 50
WORD_ALIASES = {"k8s": "kubernetes", "kube": "kubernetes", "autoscale": "autoscaling", "autoscaler": "autoscaling"}
PHRASE_ALIASES = {"auto scaling": "autoscaling", "auto scale": "autoscaling"}
TYPO_RATIO = 0.85
# Short words like cpu and gpu differ by one letter but are different topics.
TYPO_MIN_WORD_LENGTH = 6


@dataclass
class TopicActivity:
    key: str
    handles: set[str] = field(default_factory=set)
    labels: Counter = field(default_factory=Counter)

    @property
    def label(self) -> str:
        best = sorted(self.labels.items(), key=lambda item: (-item[1], item[0]))[0][0]
        return best.title() if best == best.lower() else best

    @property
    def variants(self) -> list[str]:
        return sorted(self.labels)


def normalize_topic(label: str) -> str:
    text = re.sub(r"[\W_]+", " ", unicodedata.normalize("NFKC", label).casefold()).strip()
    for phrase, replacement in PHRASE_ALIASES.items():
        text = re.sub(rf"\b{phrase}\b", replacement, text)
    return " ".join(WORD_ALIASES.get(word, word) for word in text.split())


def same_topic(first: str, second: str) -> bool:
    first_words, second_words = first.split(), second.split()
    if len(first_words) != len(second_words):
        return False
    return all(
        left == right
        or (
            min(len(left), len(right)) >= TYPO_MIN_WORD_LENGTH
            and SequenceMatcher(None, left, right).ratio() >= TYPO_RATIO
        )
        for left, right in zip(first_words, second_words, strict=True)
    )


def group_topics(pairs: Iterable[tuple[str, str]]) -> list[TopicActivity]:
    grouped: dict[str, TopicActivity] = {}
    for label, handle in pairs:
        key = normalize_topic(label)
        if key:
            activity = grouped.setdefault(key, TopicActivity(key))
            activity.handles.add(handle)
            activity.labels[label] += 1
    merged: list[TopicActivity] = []
    for activity in sorted(grouped.values(), key=lambda item: (-len(item.handles), item.key)):
        target = next((item for item in merged if same_topic(item.key, activity.key)), None)
        if target is None:
            merged.append(activity)
        else:
            target.handles |= activity.handles
            target.labels.update(activity.labels)
    return sorted(merged, key=lambda item: (-len(item.handles), item.key))


def recent_participation(
    es: Elasticsearch,
    settings: DynamicSessionSettings,
    now: datetime,
    conference: str | None = None,
) -> tuple[dict[str, list[tuple[str, str]]], bool]:
    filters = [
        {"range": {"at": {"gte": (now - timedelta(minutes=settings.window_minutes)).isoformat(), "lte": now.isoformat()}}},
        {"range": {"expires_at": {"gt": now.isoformat()}}},
    ]
    if conference:
        filters.append({"term": {"conference": conference}})
    composite = {
        "size": COMPOSITE_PAGE,
        "sources": [
            {"conference": {"terms": {"field": "conference"}}},
            {"topic": {"terms": {"field": "topics"}}},
            {"handle": {"terms": {"field": "handle"}}},
        ],
    }
    participation: dict[str, list[tuple[str, str]]] = {}
    for _ in range(MAX_PAGES):
        # Only approved moments are read; private transcripts live in another index.
        data = run_search(
            es,
            index=MOMENTS,
            size=0,
            query={"bool": {"filter": filters}},
            aggregations={"pairs": {"composite": composite}},
        )
        result = data.get("aggregations", {}).get("pairs", {})
        buckets = result.get("buckets", [])
        for bucket in buckets:
            key = bucket["key"]
            participation.setdefault(key["conference"], []).append((key["topic"], key["handle"]))
        if len(buckets) < COMPOSITE_PAGE or "after_key" not in result:
            return participation, False
        composite = {**composite, "after": result["after_key"]}
    return participation, True


def eligible_attendees(es: Elasticsearch, conference: str, now: datetime) -> int | None:
    try:
        data = run_search(
            es,
            index=PEOPLE,
            size=0,
            track_total_hits=True,
            query={"bool": {"filter": [
                {"term": {"conference": conference}},
                {"range": {"expires_at": {"gt": now.isoformat()}}},
            ]}},
        )
    except StoreError:
        return None
    total = data.get("hits", {}).get("total")
    if not isinstance(total, dict) or total.get("relation") != "eq":
        return None
    value = total.get("value")
    return value if isinstance(value, int) and not isinstance(value, bool) and value > 0 else None


def evaluate_threshold(
    unique: int, attendees: int | None, settings: DynamicSessionSettings
) -> tuple[str | None, float | None]:
    percentage = round(min(100.0, 100 * unique / attendees), 2) if attendees else None
    if unique < settings.min_unique_attendees:
        return None, percentage
    if unique >= settings.absolute_threshold:
        return "absolute", percentage
    # Comparing whole counts avoids rounding a near miss up to the threshold.
    if attendees and unique >= math.ceil(attendees * settings.percent_threshold / 100):
        return "percentage", percentage
    return None, percentage
