from datetime import datetime
from typing import Any, Dict, List, Optional

from pydantic import BaseModel, ConfigDict, Field, field_validator

from config import ANOMALY_MIN_SAMPLE_INTERVAL

SEVERITIES = ("low", "medium", "high", "critical")


class AnomalySeverity:
    low = "low"
    medium = "medium"
    high = "high"
    critical = "critical"


def severity_rank(severity: Optional[str]) -> int:
    try:
        return SEVERITIES.index((severity or "low").lower())
    except ValueError:
        return 0


# ---------------------------------------------------------------------------
# Monitor settings (single row)
# ---------------------------------------------------------------------------

class AnomalySettingsBase(BaseModel):
    is_enabled: bool = False
    sample_interval: int = Field(default=30, ge=ANOMALY_MIN_SAMPLE_INTERVAL, le=3600)
    window_seconds: int = Field(default=300, ge=30, le=86400)
    max_concurrent_networks: int = Field(default=2, ge=0, le=1000)
    max_subnets: int = Field(default=3, ge=0, le=1000)
    max_ips: int = Field(default=6, ge=0, le=1000)
    min_hits: int = Field(default=2, ge=1, le=100)
    min_traffic_rate_mbps: float = Field(default=0.0, ge=0, le=100000)
    traffic_spike_ratio: float = Field(default=0.0, ge=0, le=1000)
    cooldown_seconds: int = Field(default=900, ge=0, le=86400)
    include_ips: bool = True
    max_ips_in_report: int = Field(default=20, ge=1, le=500)


class AnomalySettingsModify(BaseModel):
    is_enabled: Optional[bool] = None
    sample_interval: Optional[int] = Field(
        default=None, ge=ANOMALY_MIN_SAMPLE_INTERVAL, le=3600
    )
    window_seconds: Optional[int] = Field(default=None, ge=30, le=86400)
    max_concurrent_networks: Optional[int] = Field(default=None, ge=0, le=1000)
    max_subnets: Optional[int] = Field(default=None, ge=0, le=1000)
    max_ips: Optional[int] = Field(default=None, ge=0, le=1000)
    min_hits: Optional[int] = Field(default=None, ge=1, le=100)
    min_traffic_rate_mbps: Optional[float] = Field(default=None, ge=0, le=100000)
    traffic_spike_ratio: Optional[float] = Field(default=None, ge=0, le=1000)
    cooldown_seconds: Optional[int] = Field(default=None, ge=0, le=86400)
    include_ips: Optional[bool] = None
    max_ips_in_report: Optional[int] = Field(default=None, ge=1, le=500)

    model_config = ConfigDict(
        json_schema_extra={
            "example": {
                "is_enabled": True,
                "sample_interval": 30,
                "window_seconds": 300,
                "max_concurrent_networks": 2,
                "max_subnets": 3,
                "min_traffic_rate_mbps": 5,
            }
        }
    )


class AnomalySettingsResponse(AnomalySettingsBase):
    created_at: Optional[datetime] = None
    updated_at: Optional[datetime] = None

    model_config = ConfigDict(from_attributes=True)


# ---------------------------------------------------------------------------
# Webhook targets
# ---------------------------------------------------------------------------

class AnomalySchedulerBase(BaseModel):
    name: str = Field(..., min_length=1, max_length=128)
    webhook_url: str = Field(..., min_length=1, max_length=1024)
    secret_key: Optional[str] = Field(default=None, max_length=256)
    interval: int = Field(default=60, ge=ANOMALY_MIN_SAMPLE_INTERVAL)
    is_enabled: bool = True
    min_severity: str = AnomalySeverity.low
    send_empty: bool = False

    @field_validator("webhook_url")
    @classmethod
    def validate_webhook_url(cls, v: str) -> str:
        v = v.strip()
        if not (v.startswith("http://") or v.startswith("https://")):
            raise ValueError("webhook_url must start with http:// or https://")
        return v

    @field_validator("min_severity")
    @classmethod
    def validate_min_severity(cls, v: str) -> str:
        v = (v or "low").strip().lower()
        if v not in SEVERITIES:
            raise ValueError(f"min_severity must be one of {', '.join(SEVERITIES)}")
        return v


class AnomalySchedulerCreate(AnomalySchedulerBase):
    model_config = ConfigDict(
        json_schema_extra={
            "example": {
                "name": "Abuse watcher",
                "webhook_url": "https://monitoring.example.com/marzban/anomalies",
                "secret_key": "super-secret-token",
                "interval": 60,
                "is_enabled": True,
                "min_severity": "medium",
                "send_empty": False,
            }
        }
    )


class AnomalySchedulerModify(BaseModel):
    name: Optional[str] = Field(default=None, min_length=1, max_length=128)
    webhook_url: Optional[str] = Field(default=None, min_length=1, max_length=1024)
    secret_key: Optional[str] = Field(default=None, max_length=256)
    interval: Optional[int] = Field(default=None, ge=ANOMALY_MIN_SAMPLE_INTERVAL)
    is_enabled: Optional[bool] = None
    min_severity: Optional[str] = None
    send_empty: Optional[bool] = None

    @field_validator("webhook_url")
    @classmethod
    def validate_webhook_url(cls, v: Optional[str]) -> Optional[str]:
        if v is None:
            return v
        v = v.strip()
        if not (v.startswith("http://") or v.startswith("https://")):
            raise ValueError("webhook_url must start with http:// or https://")
        return v

    @field_validator("min_severity")
    @classmethod
    def validate_min_severity(cls, v: Optional[str]) -> Optional[str]:
        if v is None:
            return v
        v = v.strip().lower()
        if v not in SEVERITIES:
            raise ValueError(f"min_severity must be one of {', '.join(SEVERITIES)}")
        return v


class AnomalySchedulerResponse(AnomalySchedulerBase):
    id: int
    last_run_at: Optional[datetime] = None
    last_status: Optional[str] = None
    last_status_code: Optional[int] = None
    last_error: Optional[str] = None
    total_runs: int = 0
    failed_runs: int = 0
    total_anomalies_sent: int = 0
    created_at: Optional[datetime] = None
    updated_at: Optional[datetime] = None

    model_config = ConfigDict(from_attributes=True)


# ---------------------------------------------------------------------------
# Report payload
# ---------------------------------------------------------------------------

class AnomalyReason(BaseModel):
    """A single rule that fired, with the value that tripped it."""

    rule: str
    value: float
    threshold: float


class AnomalyIp(BaseModel):
    ip: str
    last_seen: int
    network: str


class AnomalyEvidence(BaseModel):
    distinct_ips: int = 0
    distinct_subnets: int = 0
    peak_concurrent_ips: int = 0
    peak_concurrent_networks: int = 0
    ips: List[AnomalyIp] = []
    subnets: List[str] = []
    nodes: List[str] = []
    window_traffic_bytes: int = 0
    traffic_rate_bytes_per_sec: float = 0.0
    traffic_rate_mbps: float = 0.0
    baseline_rate_bytes_per_sec: float = 0.0
    traffic_ratio: float = 0.0
    samples: int = 0
    hits: int = 0
    first_seen_at: Optional[float] = None
    last_seen_at: Optional[float] = None


class AnomalyClient(BaseModel):
    """Everything about the offending subscription worth acting on."""

    username: str
    email: Optional[str] = None
    user_id: Optional[int] = None
    status: Optional[str] = None
    used_traffic: int = 0
    lifetime_used_traffic: int = 0
    data_limit: Optional[int] = None
    data_limit_reset_strategy: Optional[str] = None
    expire: Optional[int] = None
    online_at: Optional[datetime] = None
    created_at: Optional[datetime] = None
    sub_updated_at: Optional[datetime] = None
    sub_last_user_agent: Optional[str] = None
    admin: Optional[str] = None
    note: Optional[str] = None


class AnomalyRecord(BaseModel):
    username: str
    severity: str
    score: int
    reasons: List[AnomalyReason] = []
    detected_at: float
    suppressed: bool = False
    evidence: AnomalyEvidence
    client: AnomalyClient


class AnomalyMonitorInfo(BaseModel):
    is_enabled: bool = False
    ip_source: str = "unknown"
    sample_interval: int = 0
    window_seconds: int = 0
    thresholds: Dict[str, Any] = {}
    last_sample_at: Optional[float] = None
    last_error: Optional[str] = None
    nodes_sampled: List[str] = []
    nodes_failed: List[str] = []
    tracked_users: int = 0
    users_online: int = 0
    warnings: List[str] = []


class AnomalySummary(BaseModel):
    anomalies_total: int = 0
    suppressed_total: int = 0
    by_severity: Dict[str, int] = {}
    max_score: int = 0


class AnomalyReport(BaseModel):
    schema_version: str = "1.0"
    event: str = "traffic_anomaly_report"
    timestamp: float
    collected_in_ms: float = 0.0
    instance: str
    scheduler_id: Optional[int] = None
    scheduler_name: Optional[str] = None
    monitor: AnomalyMonitorInfo
    summary: AnomalySummary
    anomalies: List[AnomalyRecord] = []


class AnomalyUserActivity(BaseModel):
    """Live window state for a single user (dashboard drill-down)."""

    email: Optional[str] = None
    username: str
    distinct_ips: int = 0
    distinct_subnets: int = 0
    peak_concurrent_ips: int = 0
    peak_concurrent_networks: int = 0
    ips: List[AnomalyIp] = []
    nodes: List[str] = []
    traffic_rate_bytes_per_sec: float = 0.0
    baseline_rate_bytes_per_sec: float = 0.0
    samples: int = 0
    hits: int = 0
    first_seen_at: Optional[float] = None
    last_seen_at: Optional[float] = None
