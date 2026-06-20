from datetime import datetime
from typing import Dict, List, Optional, Union

from pydantic import BaseModel, ConfigDict, Field, field_validator

from config import PUSH_SCHEDULER_MIN_INTERVAL


class NotificationSchedulerStatus:
    success = "success"
    failed = "failed"
    pending = "pending"


class NotificationSchedulerBase(BaseModel):
    name: str = Field(..., min_length=1, max_length=128)
    webhook_url: str = Field(..., min_length=1, max_length=1024)
    secret_key: Optional[str] = Field(default=None, max_length=256)
    interval: int = Field(default=60, ge=PUSH_SCHEDULER_MIN_INTERVAL)
    is_enabled: bool = True
    include_users: bool = True

    @field_validator("webhook_url")
    @classmethod
    def validate_webhook_url(cls, v: str) -> str:
        v = v.strip()
        if not (v.startswith("http://") or v.startswith("https://")):
            raise ValueError("webhook_url must start with http:// or https://")
        return v


class NotificationSchedulerCreate(NotificationSchedulerBase):
    model_config = ConfigDict(
        json_schema_extra={
            "example": {
                "name": "Prometheus collector",
                "webhook_url": "https://monitoring.example.com/marzban/push",
                "secret_key": "super-secret-token",
                "interval": 60,
                "is_enabled": True,
                "include_users": True,
            }
        }
    )


class NotificationSchedulerModify(BaseModel):
    name: Optional[str] = Field(default=None, min_length=1, max_length=128)
    webhook_url: Optional[str] = Field(default=None, min_length=1, max_length=1024)
    secret_key: Optional[str] = Field(default=None, max_length=256)
    interval: Optional[int] = Field(default=None, ge=PUSH_SCHEDULER_MIN_INTERVAL)
    is_enabled: Optional[bool] = None
    include_users: Optional[bool] = None

    @field_validator("webhook_url")
    @classmethod
    def validate_webhook_url(cls, v: Optional[str]) -> Optional[str]:
        if v is None:
            return v
        v = v.strip()
        if not (v.startswith("http://") or v.startswith("https://")):
            raise ValueError("webhook_url must start with http:// or https://")
        return v


class NotificationSchedulerResponse(NotificationSchedulerBase):
    id: int
    last_run_at: Optional[datetime] = None
    last_status: Optional[str] = None
    last_status_code: Optional[int] = None
    last_error: Optional[str] = None
    total_runs: int = 0
    failed_runs: int = 0
    created_at: Optional[datetime] = None
    updated_at: Optional[datetime] = None

    model_config = ConfigDict(from_attributes=True)


# ---------------------------------------------------------------------------
# Standardized push payload (Prometheus / Grafana friendly)
# ---------------------------------------------------------------------------

class ServerMetrics(BaseModel):
    hostname: str
    cpu_cores: int
    cpu_usage_percent: float
    mem_total: int
    mem_used: int
    mem_free: int
    mem_usage_percent: float
    disk_total: int
    disk_used: int
    disk_free: int
    disk_usage_percent: float
    load_avg_1m: float = 0.0
    load_avg_5m: float = 0.0
    load_avg_15m: float = 0.0
    uptime_seconds: int = 0
    incoming_bandwidth_speed: int = 0
    outgoing_bandwidth_speed: int = 0


class MarzbanMetrics(BaseModel):
    version: str
    total_users: int
    users_active: int
    users_disabled: int
    users_expired: int
    users_limited: int
    users_on_hold: int
    online_users: int
    total_incoming_traffic: int
    total_outgoing_traffic: int
    total_traffic: int
    nodes_total: int = 0
    nodes_connected: int = 0


class UserMetric(BaseModel):
    username: str
    status: str
    used_traffic: int
    lifetime_used_traffic: int
    data_limit: Optional[int] = None
    data_limit_reset_strategy: Optional[str] = None
    expire: Optional[int] = None
    online_at: Optional[datetime] = None
    created_at: Optional[datetime] = None
    admin: Optional[str] = None


class PrometheusSample(BaseModel):
    """A single Prometheus-style sample. Together these form an array that can
    be transformed straight into the Prometheus exposition format or pushed to
    a Pushgateway / remote-write proxy."""

    name: str
    type: str = "gauge"
    help: str = ""
    value: Union[int, float]
    labels: Dict[str, str] = {}


class PushMetricsPayload(BaseModel):
    schema_version: str = "1.0"
    timestamp: float
    collected_in_ms: float = 0.0
    instance: str
    scheduler_id: Optional[int] = None
    scheduler_name: Optional[str] = None
    server: ServerMetrics
    marzban: MarzbanMetrics
    prometheus: List[PrometheusSample] = []
    users: Optional[List[UserMetric]] = None
