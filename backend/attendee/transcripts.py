"""Private, revisioned transcript segments in the provisioned conversations index."""

import hashlib
import json
from datetime import datetime
from typing import Annotated, Literal

from elasticsearch import ConflictError, NotFoundError
from fastapi import APIRouter, Depends, Path, Query, Request, Response
from pydantic import BaseModel, Field, field_validator

from backend.attendee.auth import Attendee, current_attendee
from backend.attendee.elastic import RETENTION, elastic_errors, get_client
from backend.models import Identifier, Input, Revision
from backend.vector_store import StoreError, utcnow

router = APIRouter()
INDEX = "conversations"
MAX_SEQUENCE = 2147483647
Sequence = Annotated[int, Path(ge=0, le=MAX_SEQUENCE)]


class SegmentWrite(Input):
    revision: Revision
    transcript: str = Field(min_length=1, max_length=20000)
    finalized: bool = Field(default=False, strict=True)
    consent: bool = Field(strict=True)

    @field_validator("consent")
    @classmethod
    def explicit_consent(cls, value):
        if not value:
            raise ValueError("Transcript upload requires consent")
        return value


class SegmentResult(BaseModel):
    stream_id: str
    sequence: int
    revision: int
    result: Literal["created", "updated", "unchanged"]


class Segment(BaseModel):
    sequence: int
    revision: int
    transcript: str
    finalized: bool
    updated_at: datetime
    expires_at: datetime


class TranscriptPage(BaseModel):
    stream_id: str
    segments: list[Segment]
    next_after: int | None


def stream_prefix(attendee, stream_id):
    identity = json.dumps([attendee.conference, attendee.handle, stream_id])
    return hashlib.sha256(identity.encode()).hexdigest() + "-"


def segment_document_id(attendee, stream_id, sequence):
    # Fixed-width suffixes sort by segment order using an existing keyword field.
    # No mapping change or reindex of existing conversations is required.
    return stream_prefix(attendee, stream_id) + f"{sequence:010d}"


def read_segment(es, doc_id):
    try:
        return es.get(index=INDEX, id=doc_id)
    except NotFoundError as error:
        if isinstance(error.body, dict) and error.body.get("found") is False:
            return None
        raise StoreError(503, "Transcript storage is not provisioned") from None


def segment_view(source):
    return {
        "sequence": int(source["conversation_id"].rsplit("-", 1)[1]),
        "revision": source["revision"],
        "transcript": source["transcript"],
        "finalized": source["is_final"],
        "updated_at": source["updated_at"],
        "expires_at": source["expires_at"],
    }


@router.put("/transcripts/{stream_id}/segments/{sequence}", response_model=SegmentResult)
def write_segment(
    stream_id: Identifier,
    sequence: Sequence,
    body: SegmentWrite,
    request: Request,
    response: Response,
    attendee: Annotated[Attendee, Depends(current_attendee)],
):
    response.headers["Cache-Control"] = "no-store"
    es = get_client(request)
    doc_id = segment_document_id(attendee, stream_id, sequence)
    result = {"stream_id": stream_id, "sequence": sequence, "revision": body.revision}
    with elastic_errors():
        for _ in range(3):
            now = utcnow()
            previous = read_segment(es, doc_id)
            old = previous["_source"] if previous else None
            if old:
                if datetime.fromisoformat(old["expires_at"]) <= now:
                    raise StoreError(410, "Recording expired; start a new segment")
                if body.revision < old["revision"]:
                    raise StoreError(409, "Stale recording revision")
                if body.revision == old["revision"]:
                    if body.transcript == old["transcript"] and body.finalized == old["is_final"]:
                        return result | {"result": "unchanged"}
                    raise StoreError(409, "Revision already exists with different content")
                if old["is_final"]:
                    raise StoreError(409, "Recording is finalized; start a new segment")
            document = {
                "conference": attendee.conference,
                "handle": attendee.handle,
                "conversation_id": doc_id,
                "revision": body.revision,
                "transcript": body.transcript,
                "consent": True,
                "visibility": "private",
                "is_final": body.finalized,
                "topics": [],
                "updated_at": now.isoformat(),
                "expires_at": old["expires_at"] if old else (now + RETENTION).isoformat(),
            }
            guard = (
                {"if_seq_no": previous["_seq_no"], "if_primary_term": previous["_primary_term"]}
                if previous else {"op_type": "create"}
            )
            try:
                # GET distinguishes an absent document from an unprovisioned index.
                # Deployment credentials must not grant auto_configure/create_index.
                es.index(index=INDEX, id=doc_id, document=document, refresh="wait_for", **guard)
                return result | {"result": "updated" if old else "created"}
            except ConflictError:
                continue
    raise StoreError(409, "Concurrent update; retry the same recording revision")


@router.get("/transcripts/{stream_id}/segments/{sequence}", response_model=Segment)
def get_segment(
    stream_id: Identifier,
    sequence: Sequence,
    request: Request,
    response: Response,
    attendee: Annotated[Attendee, Depends(current_attendee)],
):
    response.headers["Cache-Control"] = "no-store"
    with elastic_errors():
        previous = read_segment(get_client(request), segment_document_id(attendee, stream_id, sequence))
    if not previous or datetime.fromisoformat(previous["_source"]["expires_at"]) <= utcnow():
        raise StoreError(404, "Recording not found")
    return segment_view(previous["_source"])


@router.get("/transcripts/{stream_id}", response_model=TranscriptPage)
def transcript_history(
    stream_id: Identifier,
    request: Request,
    response: Response,
    attendee: Annotated[Attendee, Depends(current_attendee)],
    limit: int = Query(default=20, ge=1, le=50),
    after: int | None = Query(default=None, ge=0, le=MAX_SEQUENCE),
):
    response.headers["Cache-Control"] = "no-store"
    filters = [
        {"term": {"conference": attendee.conference}},
        {"term": {"handle": attendee.handle}},
        {"prefix": {"conversation_id": stream_prefix(attendee, stream_id)}},
        {"term": {"consent": True}},
        {"range": {"expires_at": {"gt": "now"}}},
    ]
    if after is not None:
        filters.append({"range": {"conversation_id": {
            "gt": segment_document_id(attendee, stream_id, after),
        }}})
    with elastic_errors():
        result = get_client(request).search(
            index=INDEX,
            ignore_unavailable=False,
            allow_partial_search_results=False,
            size=limit + 1,
            sort=[{"conversation_id": "asc"}],
            source_includes=["conversation_id", "transcript", "is_final", "updated_at", "expires_at", "revision"],
            query={"bool": {"filter": filters}},
        )
    if result.get("timed_out") or result.get("_shards", {}).get("failed", 0):
        raise StoreError(503, "Transcript read did not complete; retry later")
    hits = result["hits"]["hits"]
    segments = [segment_view(hit["_source"]) for hit in hits[:limit]]
    return {
        "stream_id": stream_id,
        "segments": segments,
        "next_after": segments[-1]["sequence"] if len(hits) > limit else None,
    }
