"""Conversation storage with optimistic concurrency and Elasticsearch inference."""

import hashlib
import json
from datetime import UTC, datetime, timedelta
from urllib.parse import quote

import httpx

from backend.config import Settings
from backend.models import ConversationSearch, ConversationWrite
from backend.schema import validate_mapping


class StoreError(Exception):
    def __init__(self, status: int, message: str):
        self.status = status
        self.message = message
        super().__init__(message)


def utcnow():
    return datetime.now(UTC)


def document_id(conference: str, owner_id: str, conversation_id: str):
    return hashlib.sha256(json.dumps([conference, owner_id, conversation_id]).encode()).hexdigest()


class VectorStore:
    def __init__(self, settings: Settings, client: httpx.AsyncClient, clock=utcnow):
        self.settings = settings
        self.client = client
        self.clock = clock
        self.index_path = "/" + quote(settings.index, safe="")

    async def request(self, method, path, *, allow=(), **kwargs):
        try:
            response = await self.client.request(method, path, **kwargs)
        except httpx.HTTPError as exc:
            raise StoreError(503, "Elasticsearch is unavailable; retry later") from exc
        if response.status_code in allow:
            return response
        if not response.is_success:
            # ES errors can contain source text or connection details. Do not echo them.
            raise StoreError(503, "Elasticsearch operation failed; check server configuration")
        return response

    async def ready(self):
        response = await self.request("GET", self.index_path + "/_mapping", timeout=4)
        try:
            validate_mapping(response.json(), self.settings.inference_id)
        except (ValueError, KeyError, TypeError) as exc:
            raise StoreError(503, "Conversation index schema or embedding endpoint is incompatible") from exc
        # require_alias on every write prevents accidental dynamic index creation.
        await self.request("GET", "/_alias/" + quote(self.settings.index, safe=""), timeout=4)

    async def get(self, doc_id):
        response = await self.request("GET", self.index_path + "/_doc/" + doc_id, allow=(404,))
        return None if response.status_code == 404 else response.json()

    async def replace(self, doc_id, document, previous):
        params = {"require_alias": "true", "refresh": "wait_for"}
        if previous is None:
            params["op_type"] = "create"
        else:
            params.update(if_seq_no=previous["_seq_no"], if_primary_term=previous["_primary_term"])
        return await self.request(
            "PUT",
            self.index_path + "/_doc/" + doc_id,
            params=params,
            json=document,
            allow=(409,),
        )

    async def upsert(self, conversation_id: str, incoming: ConversationWrite):
        now = self.clock()
        expiry = incoming.expires_at.astimezone(UTC)
        if not now < expiry <= now + timedelta(days=7):
            raise StoreError(422, "expires_at must be in the future and within seven days")
        payload = incoming.model_dump(mode="json")
        payload["expires_at"] = expiry.isoformat()
        digest = hashlib.sha256(json.dumps(payload, sort_keys=True).encode()).hexdigest()
        doc_id = document_id(incoming.conference, incoming.owner_id, conversation_id)
        for _ in range(3):
            previous = await self.get(doc_id)
            old = previous["_source"] if previous else None
            if old:
                if old["deleted"]:
                    raise StoreError(410, "Conversation was deleted; use a new conversation ID")
                if datetime.fromisoformat(old["expires_at"]) <= now:
                    raise StoreError(410, "Conversation has expired; use a new conversation ID")
                if incoming.revision < old["revision"]:
                    raise StoreError(409, "Stale conversation revision")
                if incoming.revision == old["revision"]:
                    if digest == old["payload_hash"]:
                        return {
                            "conversation_id": conversation_id,
                            "revision": incoming.revision,
                            "result": "unchanged",
                        }
                    raise StoreError(409, "Revision already exists with different content")
                if old["finalized"]:
                    raise StoreError(409, "Conversation is finalized")
                if payload["expires_at"] != old["expires_at"]:
                    raise StoreError(409, "Retention deadline cannot change after creation")
            document = {
                **payload,
                "conversation_id": conversation_id,
                "deleted": False,
                "payload_hash": digest,
                "updated_at": now.isoformat(),
                "created_at": old["created_at"] if old else now.isoformat(),
            }
            response = await self.replace(doc_id, document, previous)
            if response.status_code != 409:
                return {
                    "conversation_id": conversation_id,
                    "revision": incoming.revision,
                    "result": "updated" if old else "created",
                }
        raise StoreError(409, "Concurrent update; retry with the latest revision")

    async def search(self, query: ConversationSearch):
        body = {
            "size": query.limit,
            "min_score": query.min_score,
            "track_total_hits": False,
            "_source": [
                "conversation_id",
                "conference",
                "revision",
                "transcript",
                "finalized",
                "updated_at",
                "expires_at",
            ],
            "query": {
                "bool": {
                    "must": [{"match": {"transcript": {"query": query.interests}}}],
                    "filter": [
                        {"term": {"conference": query.conference}},
                        {"term": {"visibility": "conference"}},
                        {"term": {"deleted": False}},
                        {"range": {"expires_at": {"gt": "now"}}},
                    ],
                }
            },
        }
        response = await self.request(
            "POST", self.index_path + "/_search", json=body, params={"allow_partial_search_results": "false"}
        )
        data = response.json()
        if data.get("timed_out") or data.get("_shards", {}).get("failed", 0):
            raise StoreError(503, "Search did not complete; retry later")
        return {"conversations": [{**hit["_source"], "score": hit["_score"]} for hit in data["hits"]["hits"]]}

    def tombstone(self, source):
        # Keep only the identity/revision fence; remove transcript AND its vectors.
        return {key: source[key] for key in ("conversation_id", "conference", "owner_id", "revision")} | {
            "deleted": True,
            "updated_at": self.clock().isoformat(),
        }

    async def delete(self, conversation_id, conference, owner_id):
        doc_id = document_id(conference, owner_id, conversation_id)
        for _ in range(3):
            previous = await self.get(doc_id)
            if not previous:
                raise StoreError(404, "Conversation not found")
            source = previous["_source"]
            if source["deleted"]:
                return {
                    "conversation_id": conversation_id,
                    "revision": source["revision"],
                    "result": "deleted",
                }
            response = await self.replace(doc_id, self.tombstone(source), previous)
            if response.status_code != 409:
                return {
                    "conversation_id": conversation_id,
                    "revision": source["revision"],
                    "result": "deleted",
                }
        raise StoreError(409, "Concurrent update; retry deletion")

    async def expire(self, limit=100):
        # Bounded operator task. Never run unbounded scans during an API request.
        response = await self.request(
            "POST",
            self.index_path + "/_search",
            json={
                "size": limit,
                "seq_no_primary_term": True,
                "_source": ["conversation_id", "conference", "owner_id", "revision"],
                "query": {
                    "bool": {
                        "filter": [
                            {"term": {"deleted": False}},
                            {"range": {"expires_at": {"lte": "now"}}},
                        ]
                    }
                },
            },
            params={"allow_partial_search_results": "false"},
        )
        data = response.json()
        if data.get("timed_out") or data.get("_shards", {}).get("failed", 0):
            raise StoreError(503, "Expiry scan did not complete; retry later")
        removed = 0
        for hit in data["hits"]["hits"]:
            result = await self.replace(hit["_id"], self.tombstone(hit["_source"]), hit)
            removed += result.status_code != 409
        return {"expired": removed, "scanned": len(data["hits"]["hits"])}


def create_client(settings: Settings):
    settings.validate()
    return httpx.AsyncClient(
        base_url=settings.elasticsearch_url,
        headers={"Authorization": "ApiKey " + settings.elasticsearch_api_key},
        timeout=httpx.Timeout(60, connect=10),
        follow_redirects=False,
        limits=httpx.Limits(max_connections=10, max_keepalive_connections=5),
    )
