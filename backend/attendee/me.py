from typing import Annotated

from elasticsearch import ConflictError
from fastapi import APIRouter, Depends, Header, Request, Response

from backend.attendee.auth import (
    INVALID_TOKEN,
    Attendee,
    current_attendee,
    hash_token,
    is_expired,
    issue_token,
    parse_bearer,
    person_id,
    token_id,
    token_matches,
)
from backend.attendee.elastic import PEOPLE, RETENTION, elastic_errors, get_client, get_person
from backend.attendee.models import ProfileRead, ProfileResponse, ProfileWrite
from backend.vector_store import StoreError, utcnow

router = APIRouter()


def profile_view(source: dict) -> dict:
    return {
        "handle": source["handle"],
        "conference": source["conference"],
        "display_name": source.get("display_name"),
        "interests": source.get("interests", ""),
        "topics": source.get("topics", []),
        "starred_talks": source.get("starred_talks", []),
        "last_active": source["last_active"],
        "expires_at": source["expires_at"],
    }


@router.get("/me", response_model=ProfileRead, response_model_exclude_none=True)
def get_me(
    attendee: Annotated[Attendee, Depends(current_attendee)],
    request: Request,
    response: Response,
):
    response.headers["Cache-Control"] = "no-store"
    person = get_person(get_client(request), person_id(attendee.conference, attendee.handle))
    if person is None:
        raise StoreError(401, INVALID_TOKEN)
    return profile_view(person["_source"])


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
        raise StoreError(401, INVALID_TOKEN)
    if previous is not None and not token:
        raise StoreError(409, "That handle is already taken")
    if previous is not None and not token_matches(token, previous["_source"]):
        raise StoreError(401, INVALID_TOKEN)

    saved = previous["_source"] if previous else {}
    # Expired profiles count as deleted: keep the claim, not the old data.
    kept = {} if previous is None or is_expired(saved) else saved

    def chosen(field: str, default):
        value = getattr(body, field)
        return kept.get(field, default) if value is None else value

    now = utcnow()
    new_token = None if previous else issue_token(doc_id)
    document = {
        "conference": body.conference,
        "handle": body.handle,
        "token_hash": saved["token_hash"] if previous else hash_token(new_token),
        "topics": chosen("topics", []),
        "starred_talks": chosen("starred_talks", []),
        "last_active": now.isoformat(),
        "expires_at": (now + RETENTION).isoformat(),
    }
    for field in ("display_name", "interests"):
        if value := chosen(field, None):
            document[field] = value

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
    return {**profile_view(document), "created": new_token is not None, "token": new_token}
