from datetime import datetime
from typing import Annotated

from elasticsearch import ConflictError
from fastapi import APIRouter, Depends, Request, Response
from pydantic import BaseModel, Field, model_validator

from backend.attendee.auth import Attendee, current_attendee
from backend.attendee.elastic import elastic_errors, get_client
from backend.attendee.transcripts import INDEX, Sequence, read_segment, segment_document_id
from backend.models import Identifier, Input
from backend.vector_store import StoreError, utcnow

router = APIRouter()


class SharingWrite(Input):
    shared: bool = Field(strict=True)
    participants_consented: bool = Field(default=False, strict=True)

    @model_validator(mode="after")
    def sharing_needs_consent(self):
        if self.shared and not self.participants_consented:
            raise ValueError("Sharing requires confirmation that everyone recorded agreed")
        return self


class SharingResult(BaseModel):
    stream_id: str
    sequence: int
    shared: bool


@router.put("/transcripts/{stream_id}/segments/{sequence}/sharing", response_model=SharingResult)
def set_sharing(
    attendee: Annotated[Attendee, Depends(current_attendee)],
    stream_id: Identifier,
    sequence: Sequence,
    body: SharingWrite,
    request: Request,
    response: Response,
):
    response.headers["Cache-Control"] = "no-store"
    es = get_client(request)
    # The ID is derived from the token, so another attendee's segment reads as missing.
    doc_id = segment_document_id(attendee, stream_id, sequence)
    visibility = "conference" if body.shared else "private"
    with elastic_errors():
        previous = read_segment(es, doc_id)
        if not previous or datetime.fromisoformat(previous["_source"]["expires_at"]) <= utcnow():
            raise StoreError(404, "Recording not found")
        if not previous["_source"]["is_final"]:
            raise StoreError(409, "Finish the recording before sharing it")
        if previous["_source"]["visibility"] != visibility:
            try:
                es.update(
                    index=INDEX,
                    id=doc_id,
                    doc={"visibility": visibility},
                    if_seq_no=previous["_seq_no"],
                    if_primary_term=previous["_primary_term"],
                    refresh="wait_for",
                )
            except ConflictError:
                raise StoreError(409, "Recording changed; retry") from None
    return {"stream_id": stream_id, "sequence": sequence, "shared": body.shared}
