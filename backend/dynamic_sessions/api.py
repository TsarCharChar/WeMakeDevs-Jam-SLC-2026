import hmac
from typing import Annotated, Literal

from elasticsearch import Elasticsearch
from fastapi import APIRouter, Depends, Header, Query, Request, Response
from pydantic import BaseModel, Field

from backend.attendee.auth import Attendee, current_attendee, require_conference
from backend.attendee.elastic import get_client, run_search
from backend.attendee.models import StoredDate
from backend.dynamic_sessions.config import DynamicSessionSettings
from backend.dynamic_sessions.engine import run_evaluation, try_schedule
from backend.dynamic_sessions.store import INDEX, PROPOSED, SCHEDULED, SESSION, get_record
from backend.models import Identifier, Input
from backend.vector_store import StoreError, utcnow

router = APIRouter()
MINIMUM_ADMIN_TOKEN_LENGTH = 32


class DynamicSession(BaseModel):
    id: str
    type: Literal["dynamic"] = "dynamic"
    conference: str
    title: str
    description: str
    topic: str
    topics: list[str]
    attendee_count: int
    attendee_percentage: float | None = None
    start: StoredDate
    end: StoredDate
    timezone: str
    duration_minutes: int
    room: str
    room_id: str
    capacity: int
    accessibility: str | None = None
    status: Literal["scheduled"]
    demo: bool = False
    created_at: StoredDate
    expires_at: StoredDate


class DynamicSessionList(BaseModel):
    sessions: list[DynamicSession]


class RunRequest(Input):
    conference: Identifier | None = None
    dry_run: bool = Field(default=False, strict=True)


class ApproveRequest(Input):
    room_id: Identifier


def load_settings() -> DynamicSessionSettings:
    try:
        return DynamicSessionSettings.from_env()
    except ValueError:
        raise StoreError(503, "Dynamic sessions are misconfigured") from None


def require_admin(authorization: Annotated[str | None, Header()] = None) -> DynamicSessionSettings:
    settings = load_settings()
    if len(settings.admin_token) < MINIMUM_ADMIN_TOKEN_LENGTH:
        raise StoreError(503, "Dynamic session administration is not configured")
    expected = "Bearer " + settings.admin_token
    if authorization is None or not hmac.compare_digest(authorization.encode(), expected.encode()):
        raise StoreError(401, "A valid administrator token is required")
    return settings


@router.get("/dynamic-sessions", response_model=DynamicSessionList, response_model_exclude_none=True)
def list_sessions(
    attendee: Annotated[Attendee, Depends(current_attendee)],
    conference: Identifier,
    es: Annotated[Elasticsearch, Depends(get_client)],
    upcoming: bool = True,
    limit: Annotated[int, Query(ge=1, le=100)] = 50,
):
    require_conference(attendee, conference)
    filters = [
        {"term": {"record_type": SESSION}},
        {"term": {"conference": conference}},
        {"term": {"status": SCHEDULED}},
        {"range": {"expires_at": {"gt": "now"}}},
    ]
    if upcoming:
        filters.append({"range": {"end": {"gt": "now"}}})
    data = run_search(
        es,
        index=INDEX,
        size=limit,
        sort=[{"start": {"order": "asc", "unmapped_type": "date"}}],
        track_total_hits=False,
        query={"bool": {"filter": filters}},
    )
    return {"sessions": [hit["_source"] for hit in data.get("hits", {}).get("hits", [])]}


@router.post("/dynamic-sessions/run")
def run_now(
    settings: Annotated[DynamicSessionSettings, Depends(require_admin)],
    request: Request,
    response: Response,
    body: RunRequest | None = None,
):
    response.headers["Cache-Control"] = "no-store"
    body = body or RunRequest()
    summary = run_evaluation(get_client(request), settings, conference=body.conference, dry_run=body.dry_run)
    if summary["status"] == "not_provisioned":
        raise StoreError(503, "Dynamic sessions are not provisioned")
    return summary


@router.post(
    "/dynamic-sessions/{session_id}/approve",
    response_model=DynamicSession,
    response_model_exclude_none=True,
)
def approve_session(
    settings: Annotated[DynamicSessionSettings, Depends(require_admin)],
    session_id: Identifier,
    body: ApproveRequest,
    request: Request,
    response: Response,
):
    response.headers["Cache-Control"] = "no-store"
    es = get_client(request)
    hit = get_record(es, session_id)
    if not hit or hit["_source"].get("record_type") != SESSION:
        raise StoreError(404, "Dynamic session not found")
    if hit["_source"]["status"] != PROPOSED:
        raise StoreError(409, "Only a pending proposal can be approved")
    outcome = try_schedule(es, hit, utcnow(), settings, only_room=body.room_id, require_authorized=False)
    if outcome["decision"] not in ("scheduled", "already_scheduled"):
        raise StoreError(409, f"The session could not be scheduled: {outcome.get('reason', 'unknown')}")
    return get_record(es, session_id)["_source"]


@router.get("/dynamic-sessions/{session_id}", response_model=DynamicSession, response_model_exclude_none=True)
def get_session(
    attendee: Annotated[Attendee, Depends(current_attendee)],
    session_id: Identifier,
    es: Annotated[Elasticsearch, Depends(get_client)],
):
    hit = get_record(es, session_id)
    source = hit["_source"] if hit else {}
    # Proposals and other conferences read as missing so nothing unconfirmed leaks.
    if (
        source.get("record_type") != SESSION
        or source.get("conference") != attendee.conference
        or source.get("status") != SCHEDULED
    ):
        raise StoreError(404, "Dynamic session not found")
    return source
