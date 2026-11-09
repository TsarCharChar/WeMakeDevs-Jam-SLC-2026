from typing import Annotated

from elasticsearch import ConflictError
from fastapi import APIRouter, Header, Request, Response

from backend.attendee.auth import hash_token, issue_token, parse_bearer, person_id, token_id, token_matches
from backend.attendee.elastic import PEOPLE, RETENTION, elastic_errors, get_client, get_person
from backend.attendee.models import ProfileResponse, ProfileWrite
from backend.vector_store import StoreError, utcnow

router = APIRouter()


@router.put("/me", response_model=ProfileResponse, response_model_exclude_none=True)
def put_me(
    body: ProfileWrite,
    request: Request,
    response: Response,
    authorization: Annotated[str | None, Header()] = None,
):
    response.headers["Cache-Control"] = "no-store"
    token = None if authorization is None else parse_bearer(authorization)
    doc_id = person_id(body.conference, body.handle)
    if token and token_id(token) != doc_id:
        raise StoreError(403, "This token cannot change that profile")

    es = get_client(request)
    previous = get_person(es, doc_id)
    if previous is None and token:
        raise StoreError(401, "A valid attendee token is required")
    if previous is not None and not token:
        raise StoreError(409, "That handle is already taken")
    if previous is not None and not token_matches(token, previous["_source"]):
        raise StoreError(401, "A valid attendee token is required")

    now = utcnow()
    new_token = None if previous else issue_token(doc_id)
    document = {
        "conference": body.conference,
        "handle": body.handle,
        "token_hash": previous["_source"]["token_hash"] if previous else hash_token(new_token),
        "topics": body.topics,
        "starred_talks": body.starred_talks,
        "last_active": now.isoformat(),
        "expires_at": (now + RETENTION).isoformat(),
    }
    if body.interests:
        document["interests"] = body.interests

    # Creating and replacing are both conditional so concurrent requests cannot overwrite a claim.
    guard = (
        {"if_seq_no": previous["_seq_no"], "if_primary_term": previous["_primary_term"]}
        if previous
        else {"op_type": "create"}
    )
    with elastic_errors():
        try:
            es.index(index=PEOPLE, id=doc_id, document=document, **guard)
        except ConflictError:
            message = "Profile changed; retry" if previous else "That handle is already taken"
            raise StoreError(409, message) from None

    if new_token:
        response.status_code = 201
    return {
        "handle": body.handle,
        "conference": body.conference,
        "interests": body.interests,
        "topics": body.topics,
        "starred_talks": body.starred_talks,
        "last_active": document["last_active"],
        "expires_at": document["expires_at"],
        "created": new_token is not None,
        "token": new_token,
    }
