"""Opt-in conversation presence and Elasticsearch geographic search filters.

This module prepares documents; callers must authorize the conversation owner
before persisting them. It does not collect device location or expose writes.
"""

from datetime import datetime, timedelta, timezone
from typing import Annotated, Literal

from pydantic import BaseModel, ConfigDict, Field, model_validator


Identifier = Annotated[str, Field(min_length=1, max_length=128, pattern=r"\S")]


class GeoPoint(BaseModel):
    model_config = ConfigDict(extra="forbid", allow_inf_nan=False)

    lat: float = Field(ge=-90, le=90)
    lon: float = Field(ge=-180, le=180)


class ConversationCheckIn(BaseModel):
    model_config = ConfigDict(extra="forbid", allow_inf_nan=False, str_strip_whitespace=True)

    location_consent: bool = Field(strict=True)
    venue_id: Identifier
    room_id: Identifier | None = None
    zone_id: Identifier | None = None
    floor: Identifier | None = None
    location: GeoPoint | None = None
    accuracy_m: float | None = Field(default=None, ge=0, le=10000)
    source: Literal["manual_room", "qr", "device"]

    @model_validator(mode="after")
    def validate_location(self):
        if self.location_consent is not True:
            raise ValueError("Location sharing requires explicit consent")
        if self.source in {"manual_room", "qr"} and not (self.room_id or self.zone_id):
            raise ValueError("Room and QR check-ins require a room_id or zone_id")
        if self.source == "device" and (self.location is None or self.accuracy_m is None):
            raise ValueError("Device check-ins require location and accuracy_m")
        if self.accuracy_m is not None and self.location is None:
            raise ValueError("accuracy_m requires location")
        return self


def build_presence(
    check_in: ConversationCheckIn,
    *,
    conversation_expires_at: datetime,
    now: datetime | None = None,
    ttl_seconds: int = 300,
) -> dict:
    """Build a replacement presence object using server-controlled timestamps.

    Persist this with the conversation's next full revision. Do not use the
    current time to renew a cached check-in on every transcript update.
    """
    now = now or datetime.now(timezone.utc)
    if now.utcoffset() is None or conversation_expires_at.utcoffset() is None:
        raise ValueError("Presence timestamps must include a timezone")
    if not 1 <= ttl_seconds <= 900:
        raise ValueError("Presence TTL must be between 1 and 900 seconds")
    if conversation_expires_at <= now:
        raise ValueError("Cannot check into an expired conversation")
    expires_at = min(now + timedelta(seconds=ttl_seconds), conversation_expires_at)
    return {
        **check_in.model_dump(exclude={"location_consent"}, exclude_none=True),
        "shared": True,
        "updated_at": now.astimezone(timezone.utc).isoformat(),
        "expires_at": expires_at.astimezone(timezone.utc).isoformat(),
    }


class GeographicSearch(BaseModel):
    model_config = ConfigDict(extra="forbid", allow_inf_nan=False, str_strip_whitespace=True)

    conference: Identifier | None = None
    venue_id: Identifier | None = None
    room_id: Identifier | None = None
    zone_id: Identifier | None = None
    floor: Identifier | None = None
    lat: float | None = Field(default=None, ge=-90, le=90)
    lon: float | None = Field(default=None, ge=-180, le=180)
    radius_m: float | None = Field(default=None, gt=0, le=10000)

    @model_validator(mode="after")
    def validate_scope(self):
        coordinates = (self.lat, self.lon, self.radius_m)
        if any(value is not None for value in coordinates) and not all(
            value is not None for value in coordinates
        ):
            raise ValueError("lat, lon and radius_m must be supplied together")
        if self.enabled and self.conference is None:
            raise ValueError("Geographic search requires conference")
        if any(value is not None for value in (self.room_id, self.zone_id, self.floor)):
            if self.venue_id is None:
                raise ValueError("Room, zone and floor filters require venue_id")
        return self

    @property
    def enabled(self) -> bool:
        return any(value is not None for value in (
            self.venue_id, self.room_id, self.zone_id, self.floor,
            self.lat, self.lon, self.radius_m,
        ))

    def filters(self) -> list[dict]:
        filters = []
        if self.conference is not None:
            filters.append({"term": {"conference": self.conference}})
        if not self.enabled:
            return filters
        filters.extend([
            {"term": {"presence.shared": True}},
            {"range": {"presence.expires_at": {"gt": "now"}}},
            {"range": {"presence.updated_at": {"lte": "now"}}},
            {"range": {"expires_at": {"gt": "now"}}},
        ])
        for field in ("venue_id", "room_id", "zone_id", "floor"):
            value = getattr(self, field)
            if value is not None:
                filters.append({"term": {f"presence.{field}": value}})
        if self.lat is not None:
            filters.append({"geo_distance": {
                "distance": f"{self.radius_m}m",
                "presence.location": {"lat": self.lat, "lon": self.lon},
                "ignore_unmapped": True,
            }})
        return filters
