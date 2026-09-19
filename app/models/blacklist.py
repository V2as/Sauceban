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


class BlacklistResponse(BaseModel):
    entries: List[BlacklistEntryResponse] = []
    status: BlacklistStatus
