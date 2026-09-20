from datetime import datetime
from typing import List, Optional

from pydantic import BaseModel, ConfigDict, Field

from config import BLACKLIST_MAX_MBPS


class BlacklistEntryCreate(BaseModel):
    username: str = Field(..., min_length=1, max_length=34)
    limit_mbps: int = Field(..., ge=1, le=BLACKLIST_MAX_MBPS)
    is_enabled: bool = True
    reason: Optional[str] = Field(default=None, max_length=500)

    model_config = ConfigDict(
        json_schema_extra={
            "example": {
                "username": "heavy_torrenter",
                "limit_mbps": 10,
                "is_enabled": True,
                "reason": "saturating the uplink every evening",
            }
        }
    )


class BlacklistEntryModify(BaseModel):
    limit_mbps: Optional[int] = Field(default=None, ge=1, le=BLACKLIST_MAX_MBPS)
    is_enabled: Optional[bool] = None
    reason: Optional[str] = Field(default=None, max_length=500)


class BlacklistEntryResponse(BaseModel):
    id: int
    user_id: int
    username: str
    limit_mbps: int
    is_enabled: bool
    reason: Optional[str] = None
    # manual | anomaly — who put the cap here. Automatic caps expire on their
    # own; editing one through this API makes it manual.
    source: str = "manual"
    expires_at: Optional[datetime] = None
    created_at: Optional[datetime] = None
    updated_at: Optional[datetime] = None

    # live state, not stored: the addresses the cap is currently installed for
    # and what it has cost this user since the class was created
    active_ips: List[str] = []
    shaped_bytes: int = 0
    dropped_packets: int = 0

    model_config = ConfigDict(from_attributes=True)


class GlobalLimitModify(BaseModel):
    """Partial update of the panel-wide cap. Field names match the columns."""

    global_enabled: Optional[bool] = None
    global_mbps: Optional[int] = Field(default=None, ge=1, le=BLACKLIST_MAX_MBPS)

    model_config = ConfigDict(
        json_schema_extra={
            "example": {"global_enabled": True, "global_mbps": 200}
        }
    )


class GlobalLimitStatus(BaseModel):
    """The panel-wide cap: what is configured and whether it is installed.

    The cap is enforced per address, so the number here is what a single client
    address gets in each direction — not a budget shared by everyone.
    """

    global_enabled: bool = False
    global_mbps: int = 200
    available: bool = True
    unavailable_reason: Optional[str] = None
    interface: Optional[str] = None
    # kernel counters of what the cap dropped since it was installed
    dropped_packets_down: int = 0
    dropped_packets_up: int = 0
    last_applied_at: Optional[float] = None
    last_error: Optional[str] = None


class BlacklistStatus(BaseModel):
    """Whether the caps are actually being enforced, and by what."""

    enforce: bool
    available: bool
    unavailable_reason: Optional[str] = None
    interface: Optional[str] = None
    # bulk | probe | unavailable — how the source IPs of capped users are read
    # from the core, see app/jobs/sync_blacklist.py
    ip_source: str = "unavailable"
    entries_total: int = 0
    shaped_users: int = 0
    shaped_ips: int = 0
    last_sync_at: Optional[float] = None
    last_applied_at: Optional[float] = None
    last_error: Optional[str] = None
    # the panel-wide cap, enforced independently of the entries above
    global_limit: GlobalLimitStatus = Field(default_factory=GlobalLimitStatus)


class BlacklistResponse(BaseModel):
    entries: List[BlacklistEntryResponse] = []
    status: BlacklistStatus
