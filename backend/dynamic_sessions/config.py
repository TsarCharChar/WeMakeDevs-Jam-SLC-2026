import os
from dataclasses import dataclass, field


def _number(name: str, default, cast, minimum):
    raw = os.getenv(name, "").strip()
    if not raw:
        return default
    try:
        value = cast(raw)
    except ValueError:
        raise ValueError(f"{name} must be a number") from None
    if not value >= minimum:
        raise ValueError(f"{name} must be at least {minimum}")
    return value


@dataclass(frozen=True)
class DynamicSessionSettings:
    window_minutes: int = 30
    percent_threshold: float = 5.0
    absolute_threshold: int = 50
    min_unique_attendees: int = 3
    duration_minutes: int = 30
    lead_minutes: int = 15
    horizon_minutes: int = 240
    cooldown_minutes: int = 120
    max_new_per_run: int = 3
    admin_token: str = field(default="", repr=False)

    @classmethod
    def from_env(cls):
        return cls(
            window_minutes=_number("DYNAMIC_SESSIONS_WINDOW_MINUTES", 30, int, 1),
            percent_threshold=_number("DYNAMIC_SESSIONS_PERCENT_THRESHOLD", 5.0, float, 0.01),
            absolute_threshold=_number("DYNAMIC_SESSIONS_ABSOLUTE_THRESHOLD", 50, int, 1),
            min_unique_attendees=_number("DYNAMIC_SESSIONS_MIN_UNIQUE_ATTENDEES", 3, int, 1),
            duration_minutes=_number("DYNAMIC_SESSIONS_DURATION_MINUTES", 30, int, 5),
            lead_minutes=_number("DYNAMIC_SESSIONS_LEAD_MINUTES", 15, int, 0),
            horizon_minutes=_number("DYNAMIC_SESSIONS_HORIZON_MINUTES", 240, int, 5),
            cooldown_minutes=_number("DYNAMIC_SESSIONS_COOLDOWN_MINUTES", 120, int, 1),
            max_new_per_run=_number("DYNAMIC_SESSIONS_MAX_NEW_PER_RUN", 3, int, 1),
            admin_token=os.getenv("DYNAMIC_SESSIONS_ADMIN_TOKEN", ""),
        )
