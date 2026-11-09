from datetime import datetime
from typing import Annotated, Literal

from pydantic import AwareDatetime, BaseModel, ConfigDict, Field, StringConstraints

Identifier = Annotated[str, StringConstraints(pattern=r"^[A-Za-z0-9][A-Za-z0-9_-]{0,127}$")]
Revision = Annotated[int, Field(strict=True, ge=1, le=9223372036854775807)]


class Input(BaseModel):
    model_config = ConfigDict(extra="forbid", str_strip_whitespace=True)


class ConversationWrite(Input):
    conference: Identifier
    owner_id: Identifier
    revision: Revision
    transcript: str = Field(min_length=1, max_length=20000)
    expires_at: AwareDatetime
    visibility: Literal["private", "conference"] = "private"
    finalized: bool = False


class ConversationSearch(Input):
    conference: Identifier
    interests: str = Field(min_length=1, max_length=500)
    limit: int = Field(default=10, ge=1, le=50, strict=True)
    min_score: float = Field(default=0, ge=0, allow_inf_nan=False)


class ConversationResult(BaseModel):
    conversation_id: str
    conference: str
    revision: int
    transcript: str
    finalized: bool
    updated_at: datetime
    expires_at: datetime
    score: float


class SearchResults(BaseModel):
    conversations: list[ConversationResult]


class WriteResult(BaseModel):
    conversation_id: str
    revision: int
    result: Literal["created", "updated", "unchanged", "deleted"]
