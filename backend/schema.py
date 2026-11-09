"""Explicit Serverless mappings: no unmanaged shard/replica settings."""

SCHEMA_VERSION = 1


def conversation_mapping(inference_id: str):
    if not inference_id:
        raise ValueError("An explicit inference endpoint is required")
    return {
        "dynamic": "strict",
        "_meta": {"conversation_schema_version": SCHEMA_VERSION},
        "properties": {
            "conversation_id": {"type": "keyword"},
            "conference": {"type": "keyword"},
            "owner_id": {"type": "keyword"},
            "revision": {"type": "long"},
            "transcript": {
                "type": "semantic_text",
                "inference_id": inference_id,
                "search_inference_id": inference_id,
            },
            "visibility": {"type": "keyword"},
            "finalized": {"type": "boolean"},
            "deleted": {"type": "boolean"},
            "payload_hash": {"type": "keyword", "index": False, "doc_values": False},
            "created_at": {"type": "date"},
            "updated_at": {"type": "date"},
            "expires_at": {"type": "date"},
        },
    }


def validate_mapping(response: dict, inference_id: str):
    # A multi-index alias could return duplicates or mix embedding spaces.
    if len(response) != 1:
        raise ValueError("Conversation alias must resolve to exactly one index")
    mapping = next(iter(response.values())).get("mappings", {})
    expected = conversation_mapping(inference_id)
    if (
        mapping.get("dynamic") != "strict"
        or mapping.get("_meta", {}).get("conversation_schema_version") != SCHEMA_VERSION
    ):
        raise ValueError("Conversation index requires explicit schema provisioning")
    fields = mapping.get("properties", {})
    for name, definition in expected["properties"].items():
        actual = fields.get(name, {})
        for key, value in definition.items():
            if key == "search_inference_id" and actual.get(key, actual.get("inference_id")) == value:
                continue
            if actual.get(key) != value:
                raise ValueError(f"Conversation field {name} has incompatible {key}")
