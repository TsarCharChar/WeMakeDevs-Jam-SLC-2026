import hashlib
import hmac
import json
import re
import secrets
from dataclasses import dataclass
from datetime import datetime
from typing import Annotated

from fastapi import Header, Request

from backend.attendee.elastic import get_client, get_person
from backend.vector_store import StoreError, utcnow

# token_hash is not indexed, so the token carries the profile ID used to look it up.
TOKEN_PATTERN = re.compile(r"[0-9a-f]{64}\.[A-Za-z0-9_-]{43}")
INVALID_TOKEN = "A valid attendee token is required"


@dataclass(frozen=True)
class Attendee:
    conference: str
    handle: str


def person_id(conference: str, handle: str) -> str:
    return hashlib.sha256(json.dumps([conference, handle]).encode()).hexdigest()


def issue_token(doc_id: str) -> str:
    return f"{doc_id}.{secrets.token_urlsafe(32)}"


def hash_token(token: str) -> str:
    return hashlib.sha256(token.encode()).hexdigest()


def token_id(token: str) -> str:
    return token.partition(".")[0]


def parse_bearer(authorization: str | None) -> str:
    scheme, _, token = (authorization or "").partition(" ")
    if scheme.lower() != "bearer" or not TOKEN_PATTERN.fullmatch(token):
        raise StoreError(401, INVALID_TOKEN)
    return token


def token_matches(token: str, source: dict) -> bool:
    stored = source.get("token_hash")
    return isinstance(stored, str) and hmac.compare_digest(stored.encode(), hash_token(token).encode())


def is_expired(source: dict) -> bool:
    try:
        return datetime.fromisoformat(source["expires_at"]) <= utcnow()
    except (KeyError, TypeError, ValueError):
        return True


def current_attendee(request: Request, authorization: Annotated[str | None, Header()] = None) -> Attendee:
    token = parse_bearer(authorization)
    person = get_person(get_client(request), token_id(token))
    if person is None:
        raise StoreError(401, INVALID_TOKEN)
    source = person["_source"]
    if not token_matches(token, source) or is_expired(source):
        raise StoreError(401, INVALID_TOKEN)
    return Attendee(conference=source["conference"], handle=source["handle"])


def require_conference(attendee: Attendee, conference: str):
    if conference != attendee.conference:
        raise StoreError(403, "This token belongs to a different conference")
