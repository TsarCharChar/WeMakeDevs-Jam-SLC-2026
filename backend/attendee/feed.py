from typing import Annotated

from fastapi import APIRouter, Depends, Query, Request

from backend.attendee.auth import Attendee, current_attendee
from backend.attendee.elastic import ALERTS, get_client, run_search, visible_in
from backend.attendee.models import FeedResponse
from backend.models import Identifier
from backend.vector_store import StoreError

router = APIRouter()


@router.get("/feed", response_model=FeedResponse)
def get_feed(
    attendee: Annotated[Attendee, Depends(current_attendee)],
    request: Request,
    conference: Identifier | None = None,
    limit: Annotated[int, Query(ge=1, le=100)] = 20,
):
    if conference is not None and conference != attendee.conference:
        raise StoreError(403, "This token belongs to a different conference")
    # The recipient only ever comes from the token, so query parameters cannot change it.
    data = run_search(
        get_client(request),
        index=ALERTS,
        size=limit,
        source=["kind", "room", "why", "seen", "at"],
        sort=[{"at": {"order": "desc", "unmapped_type": "date"}}],
        track_total_hits=False,
        query={"bool": {"filter": [*visible_in(attendee.conference), {"term": {"to_handle": attendee.handle}}]}},
    )
    return {"alerts": [{**hit["_source"], "id": hit["_id"]} for hit in data.get("hits", {}).get("hits", [])]}
