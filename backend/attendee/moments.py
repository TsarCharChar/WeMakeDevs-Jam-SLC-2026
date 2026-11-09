from datetime import UTC
from typing import Annotated
from uuid import uuid4

from fastapi import APIRouter, Depends, Request

from backend.attendee.auth import Attendee, current_attendee, require_conference
from backend.attendee.elastic import MOMENTS, RETENTION, elastic_errors, get_client
from backend.attendee.models import MomentCreated, MomentWrite
from backend.vector_store import StoreError, utcnow

router = APIRouter()


@router.post("/moments", status_code=201, response_model=MomentCreated)
def create_moment(
    attendee: Annotated[Attendee, Depends(current_attendee)],
    body: MomentWrite,
    request: Request,
):
    require_conference(attendee, body.conference)
    now = utcnow()
    expiry = body.expires_at.astimezone(UTC) if body.expires_at else now + RETENTION
    if not now < expiry <= now + RETENTION:
        raise StoreError(422, "expires_at must be in the future and within seven days")

    es = get_client(request)
    moment_id = uuid4().hex
    with elastic_errors():
        # Indexing into a missing index would auto-create it with the wrong mapping.
        if not es.indices.exists(index=MOMENTS):
            raise StoreError(503, "Moments are not provisioned")
        es.index(
            index=MOMENTS,
            id=moment_id,
            op_type="create",
            document={
                "conference": attendee.conference,
                "handle": attendee.handle,
                "source": body.source,
                "gist": body.gist,
                "topics": body.topics,
                "at": now.isoformat(),
                "expires_at": expiry.isoformat(),
            },
        )
    return {
        "id": moment_id,
        "conference": attendee.conference,
        "at": now.isoformat(),
        "expires_at": expiry.isoformat(),
    }
