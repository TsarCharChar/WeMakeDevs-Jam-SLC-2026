from typing import Annotated, Literal

from pydantic import AfterValidator, AwareDatetime, BaseModel, Field, StringConstraints

from backend.models import Identifier, Input

Handle = Annotated[str, StringConstraints(pattern=r"^[A-Za-z0-9][A-Za-z0-9_-]{1,31}$")]
Topic = Annotated[str, StringConstraints(min_length=1, max_length=64, pattern=r"^[^\x00-\x1f\x7f]+$")]
TalkId = Annotated[str, StringConstraints(pattern=r"^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$")]
DisplayName = Annotated[str, StringConstraints(min_length=1, max_length=60, pattern=r"^[^\x00-\x1f\x7f]+$")]
StoredDate = str | int | None


def distinct_topics(topics: list[str]) -> list[str]:
    # Case variants like eBPF and ebpf would otherwise split into two graph nodes.
    unique = {}
    for topic in topics:
        unique.setdefault(topic.casefold(), topic)
    return list(unique.values())


def distinct(values: list[str]) -> list[str]:
    return list(dict.fromkeys(values))


class ProfileWrite(Input):
    handle: Handle
    conference: Identifier
    display_name: DisplayName | None = None
    # None means the field was left out, so updates can keep what is saved.
    interests: str | None = Field(default=None, max_length=1000)
    topics: Annotated[list[Topic], Field(max_length=20), AfterValidator(distinct_topics)] | None = None
    starred_talks: Annotated[list[TalkId], Field(max_length=100), AfterValidator(distinct)] | None = None


class ProfileRead(BaseModel):
    handle: str
    conference: str
    display_name: str | None = None
    interests: str
    topics: list[str]
    starred_talks: list[str]
    last_active: str
    expires_at: str


class ProfileResponse(ProfileRead):
    created: bool
    token: str | None = None


class MomentWrite(Input):
    conference: Identifier
    # Keeps this a one-line summary and rejects pasted transcripts.
    gist: str = Field(min_length=1, max_length=280, pattern=r"^[^\x00-\x1f\x7f]+$")
    topics: Annotated[list[Topic], Field(min_length=1, max_length=5), AfterValidator(distinct_topics)]
    source: Literal["spoken", "notes"]
    approved: Literal[True]
    expires_at: AwareDatetime | None = None


class MomentCreated(BaseModel):
    id: str
    conference: str
    at: str
    expires_at: str


class GraphNode(BaseModel):
    id: str
    label: str
    count: int


class GraphEdge(BaseModel):
    source: str
    target: str
    weight: int


class GraphResponse(BaseModel):
    conference: str
    nodes: list[GraphNode]
    edges: list[GraphEdge]


class SearchHit(BaseModel):
    type: Literal["talk", "moment"]
    id: str
    score: float
    topics: list[str] = []
    title: str | None = None
    abstract: str | None = None
    speakers: list[str] | None = None
    room: str | None = None
    start: StoredDate = None
    end: StoredDate = None
    gist: str | None = None
    source: str | None = None
    at: StoredDate = None


class ContentSearchResponse(BaseModel):
    query: str
    conference: str
    mode: Literal["hybrid", "keyword"]
    results: list[SearchHit]


class FeedAlert(BaseModel):
    id: str
    kind: str | None = None
    room: str | None = None
    why: str | None = None
    seen: bool = False
    at: StoredDate = None


class FeedResponse(BaseModel):
    alerts: list[FeedAlert]
