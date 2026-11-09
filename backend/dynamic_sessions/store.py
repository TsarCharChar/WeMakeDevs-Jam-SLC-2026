import hashlib
import json

from elasticsearch import ConflictError, Elasticsearch, NotFoundError

from backend.attendee.elastic import elastic_errors

INDEX = "dynamic_sessions"
SESSION = "session"
ROOM = "room"
LOCK = "room_lock"
PROPOSED = "proposed"
SCHEDULED = "scheduled"
CANCELLED = "cancelled"


def stable_id(prefix: str, *parts) -> str:
    return f"{prefix}-" + hashlib.sha256(json.dumps(parts).encode()).hexdigest()[:40]


def provisioned(es: Elasticsearch) -> bool:
    # Indexing into a missing index would auto-create it with the wrong mapping.
    with elastic_errors():
        return bool(es.indices.exists(index=INDEX))


def get_record(es: Elasticsearch, doc_id: str) -> dict | None:
    with elastic_errors():
        try:
            return es.get(index=INDEX, id=doc_id)
        except NotFoundError:
            return None


def create_record(es: Elasticsearch, doc_id: str, document: dict) -> bool:
    # A create either wins or conflicts, which keeps overlapping runs exactly-once.
    with elastic_errors():
        try:
            es.index(index=INDEX, id=doc_id, document=document, op_type="create", refresh="wait_for")
        except ConflictError:
            return False
    return True


def update_record(es: Elasticsearch, hit: dict, changes: dict) -> bool:
    with elastic_errors():
        try:
            es.update(
                index=INDEX,
                id=hit["_id"],
                doc=changes,
                if_seq_no=hit["_seq_no"],
                if_primary_term=hit["_primary_term"],
                refresh="wait_for",
            )
        except ConflictError:
            return False
    return True


def delete_record(es: Elasticsearch, doc_id: str) -> None:
    with elastic_errors():
        try:
            es.delete(index=INDEX, id=doc_id, refresh="wait_for")
        except NotFoundError:
            return
