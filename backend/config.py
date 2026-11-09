"""Server-only Elasticsearch configuration. Never load credentials from Git."""

import os
import re
from dataclasses import dataclass, field
from urllib.parse import urlsplit


@dataclass(frozen=True)
class Settings:
    elasticsearch_url: str = ""
    elasticsearch_api_key: str = field(default="", repr=False)
    index: str = "conversation-garden-conversations"
    inference_id: str = ""
    service_token: str = field(default="", repr=False)

    @classmethod
    def from_env(cls):
        return cls(
            elasticsearch_url=os.getenv("ELASTICSEARCH_URL", "").rstrip("/"),
            elasticsearch_api_key=os.getenv("ELASTICSEARCH_API_KEY", ""),
            index=os.getenv("ELASTICSEARCH_INDEX", "conversation-garden-conversations"),
            inference_id=os.getenv("ELASTICSEARCH_INFERENCE_ID", ""),
            service_token=os.getenv("CONVERSATION_API_TOKEN", ""),
        )

    @property
    def enabled(self):
        # URL/key alone already power the public synthetic-session endpoint.
        # Activate the new vector API only when its specific configuration is supplied.
        return bool(self.inference_id or self.service_token)

    @property
    def configured(self):
        return bool(
            self.elasticsearch_url
            and self.elasticsearch_api_key
            and self.inference_id
            and len(self.service_token) >= 32
        )

    def validate(self):
        if not self.configured:
            raise ValueError("Vector search is not configured")
        url = urlsplit(self.elasticsearch_url)
        if (
            url.scheme != "https"
            or not url.hostname
            or url.username
            or url.password
            or url.query
            or url.fragment
            or url.path not in ("", "/")
        ):
            raise ValueError("ELASTICSEARCH_URL must be an HTTPS origin")
        if not re.fullmatch(r"[a-z0-9][a-z0-9_-]{0,199}", self.index):
            raise ValueError("ELASTICSEARCH_INDEX must be a single index alias")
