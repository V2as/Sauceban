"""Lightweight collection of server + marzban metrics for push webhooks.

The collector is intentionally cheap: it performs a small number of aggregate
SQL queries (no per-user relationship loading / N+1) and reuses psutil's
non-blocking sampling. A short-lived in-memory snapshot cache makes sure that
several schedulers firing at the same time only trigger a single collection,
so enabling push metrics never slows down the API.
"""
import os
import socket
import time
from threading import Lock
from typing import Optional

import psutil
from sqlalchemy import func

from app import __version__
from app.db import GetDB
from app.db.models import Node, System, User, UserUsageResetLogs
from app.db.models import Admin as DBAdmin
from app.models.notification_scheduler import (MarzbanMetrics,
                                               PrometheusSample,
                                               PushMetricsPayload,
                                               ServerMetrics, UserMetric)
from app.models.user import UserStatus
from app.utils.system import cpu_usage, memory_usage, realtime_bandwidth
from config import PUSH_METRICS_CACHE_TTL

_cache_lock = Lock()
# keyed by `include_users` -> (expires_at, PushMetricsPayload)
_snapshot_cache: dict = {}


def _collect_server_metrics() -> ServerMetrics:
    mem = memory_usage()
    cpu = cpu_usage()
    rt = realtime_bandwidth()

    try:
        disk = psutil.disk_usage("/")
        disk_total, disk_used, disk_free, disk_percent = (
            disk.total, disk.used, disk.free, disk.percent
        )
    except Exception:
        disk_total = disk_used = disk_free = 0
        disk_percent = 0.0

    try:
        load1, load5, load15 = os.getloadavg()
    except (OSError, AttributeError):
        load1 = load5 = load15 = 0.0

    try:
        uptime = int(time.time() - psutil.boot_time())
    except Exception:
        uptime = 0

    mem_percent = round((mem.used / mem.total) * 100, 2) if mem.total else 0.0

    return ServerMetrics(
        hostname=socket.gethostname(),
        cpu_cores=cpu.cores,
        cpu_usage_percent=cpu.percent,
        mem_total=mem.total,
        mem_used=mem.used,
        mem_free=mem.free,
        mem_usage_percent=mem_percent,
        disk_total=disk_total,
        disk_used=disk_used,
        disk_free=disk_free,
        disk_usage_percent=disk_percent,
        load_avg_1m=round(load1, 2),
        load_avg_5m=round(load5, 2),
        load_avg_15m=round(load15, 2),
        uptime_seconds=uptime,
        incoming_bandwidth_speed=rt.incoming_bytes,
        outgoing_bandwidth_speed=rt.outgoing_bytes,
    )


def _collect_marzban_metrics(db) -> MarzbanMetrics:
    # single grouped query instead of one query per status
    status_counts = dict(
        db.query(User.status, func.count(User.id)).group_by(User.status).all()
    )

    def count(status: UserStatus) -> int:
        return int(status_counts.get(status, 0) or 0)

    total = int(sum(status_counts.values()))

    from datetime import datetime, timedelta
    online_users = int(
        db.query(func.count(User.id))
        .filter(User.online_at.isnot(None),
                User.online_at >= datetime.utcnow() - timedelta(hours=24))
        .scalar() or 0
    )

    system: Optional[System] = db.query(System).first()
    uplink = int(system.uplink if system else 0)
    downlink = int(system.downlink if system else 0)

    nodes_total = int(db.query(func.count(Node.id)).scalar() or 0)
    nodes_connected = 0
    try:
        from app import xray
        nodes_connected = sum(
            1 for node in list(xray.nodes.values())
            if getattr(node, "connected", False) and getattr(node, "started", False)
        )
    except Exception:
        nodes_connected = 0

    return MarzbanMetrics(
        version=__version__,
        total_users=total,
        users_active=count(UserStatus.active),
        users_disabled=count(UserStatus.disabled),
        users_expired=count(UserStatus.expired),
        users_limited=count(UserStatus.limited),
        users_on_hold=count(UserStatus.on_hold),
        online_users=online_users,
        total_incoming_traffic=uplink,
        total_outgoing_traffic=downlink,
        total_traffic=uplink + downlink,
        nodes_total=nodes_total,
        nodes_connected=nodes_connected,
    )


def _collect_users(db) -> list:
    # bulk reseted-usage map to compute lifetime traffic without N+1
    reseted = dict(
        db.query(UserUsageResetLogs.user_id,
                 func.sum(UserUsageResetLogs.used_traffic_at_reset))
        .group_by(UserUsageResetLogs.user_id)
        .all()
    )
    admins = dict(db.query(DBAdmin.id, DBAdmin.username).all())

    rows = db.query(
        User.id,
        User.username,
        User.status,
        User.used_traffic,
        User.data_limit,
        User.data_limit_reset_strategy,
        User.expire,
        User.online_at,
        User.created_at,
        User.admin_id,
    ).all()

    users = []
    for r in rows:
        used = int(r.used_traffic or 0)
        lifetime = used + int(reseted.get(r.id, 0) or 0)
        status = r.status.value if hasattr(r.status, "value") else str(r.status)
        strategy = (
            r.data_limit_reset_strategy.value
            if hasattr(r.data_limit_reset_strategy, "value")
            else (str(r.data_limit_reset_strategy) if r.data_limit_reset_strategy else None)
        )
        users.append(UserMetric(
            username=r.username,
            status=status,
            used_traffic=used,
            lifetime_used_traffic=lifetime,
            data_limit=int(r.data_limit) if r.data_limit is not None else None,
            data_limit_reset_strategy=strategy,
            expire=r.expire,
            online_at=r.online_at,
            created_at=r.created_at,
            admin=admins.get(r.admin_id),
        ))
    return users


def _build_prometheus_samples(server: ServerMetrics, marzban: MarzbanMetrics) -> list:
    samples = [
        PrometheusSample(name="marzban_up", type="gauge",
                         help="Whether the marzban instance is up", value=1),
        PrometheusSample(name="marzban_cpu_cores", type="gauge",
                         help="Number of CPU cores", value=server.cpu_cores),
        PrometheusSample(name="marzban_cpu_usage_percent", type="gauge",
                         help="CPU usage percent", value=server.cpu_usage_percent),
        PrometheusSample(name="marzban_memory_total_bytes", type="gauge",
                         help="Total memory in bytes", value=server.mem_total),
        PrometheusSample(name="marzban_memory_used_bytes", type="gauge",
                         help="Used memory in bytes", value=server.mem_used),
        PrometheusSample(name="marzban_memory_free_bytes", type="gauge",
                         help="Free memory in bytes", value=server.mem_free),
        PrometheusSample(name="marzban_memory_usage_percent", type="gauge",
                         help="Memory usage percent", value=server.mem_usage_percent),
        PrometheusSample(name="marzban_disk_total_bytes", type="gauge",
                         help="Total disk in bytes", value=server.disk_total),
        PrometheusSample(name="marzban_disk_used_bytes", type="gauge",
                         help="Used disk in bytes", value=server.disk_used),
        PrometheusSample(name="marzban_disk_usage_percent", type="gauge",
                         help="Disk usage percent", value=server.disk_usage_percent),
        PrometheusSample(name="marzban_load1", type="gauge",
                         help="1m load average", value=server.load_avg_1m),
        PrometheusSample(name="marzban_load5", type="gauge",
                         help="5m load average", value=server.load_avg_5m),
        PrometheusSample(name="marzban_load15", type="gauge",
                         help="15m load average", value=server.load_avg_15m),
        PrometheusSample(name="marzban_uptime_seconds", type="counter",
                         help="System uptime in seconds", value=server.uptime_seconds),
        PrometheusSample(name="marzban_bandwidth_incoming_bytes_per_second", type="gauge",
                         help="Realtime incoming bandwidth", value=server.incoming_bandwidth_speed),
        PrometheusSample(name="marzban_bandwidth_outgoing_bytes_per_second", type="gauge",
                         help="Realtime outgoing bandwidth", value=server.outgoing_bandwidth_speed),

        PrometheusSample(name="marzban_users_total", type="gauge",
                         help="Total number of users", value=marzban.total_users),
        PrometheusSample(name="marzban_users", type="gauge",
                         help="Users by status", value=marzban.users_active,
                         labels={"status": "active"}),
        PrometheusSample(name="marzban_users", type="gauge",
                         help="Users by status", value=marzban.users_disabled,
                         labels={"status": "disabled"}),
        PrometheusSample(name="marzban_users", type="gauge",
                         help="Users by status", value=marzban.users_expired,
                         labels={"status": "expired"}),
        PrometheusSample(name="marzban_users", type="gauge",
                         help="Users by status", value=marzban.users_limited,
                         labels={"status": "limited"}),
        PrometheusSample(name="marzban_users", type="gauge",
                         help="Users by status", value=marzban.users_on_hold,
                         labels={"status": "on_hold"}),
        PrometheusSample(name="marzban_online_users", type="gauge",
                         help="Online users (last 24h)", value=marzban.online_users),
        PrometheusSample(name="marzban_traffic_incoming_bytes_total", type="counter",
                         help="Total incoming traffic in bytes", value=marzban.total_incoming_traffic),
        PrometheusSample(name="marzban_traffic_outgoing_bytes_total", type="counter",
                         help="Total outgoing traffic in bytes", value=marzban.total_outgoing_traffic),
        PrometheusSample(name="marzban_traffic_bytes_total", type="counter",
                         help="Total traffic in bytes", value=marzban.total_traffic),
        PrometheusSample(name="marzban_nodes_total", type="gauge",
                         help="Total number of nodes", value=marzban.nodes_total),
        PrometheusSample(name="marzban_nodes_connected", type="gauge",
                         help="Number of connected nodes", value=marzban.nodes_connected),
    ]
    return samples


def collect_metrics(include_users: bool = True,
                    scheduler_id: Optional[int] = None,
                    scheduler_name: Optional[str] = None,
                    use_cache: bool = True) -> PushMetricsPayload:
    """Collect a full metrics snapshot.

    A snapshot is cached for ``PUSH_METRICS_CACHE_TTL`` seconds (keyed by
    ``include_users``) so simultaneous schedulers reuse the same collection.
    The scheduler id/name are stamped on the (copied) payload afterwards.
    """
    cache_key = bool(include_users)
    now = time.time()

    if use_cache:
        with _cache_lock:
            cached = _snapshot_cache.get(cache_key)
            if cached and cached[0] > now:
                payload = cached[1].model_copy(deep=True)
                payload.scheduler_id = scheduler_id
                payload.scheduler_name = scheduler_name
                return payload

    started = time.perf_counter()
    server = _collect_server_metrics()
    with GetDB() as db:
        marzban = _collect_marzban_metrics(db)
        users = _collect_users(db) if include_users else None
    samples = _build_prometheus_samples(server, marzban)
    collected_in_ms = round((time.perf_counter() - started) * 1000, 2)

    payload = PushMetricsPayload(
        timestamp=now,
        collected_in_ms=collected_in_ms,
        instance=server.hostname,
        scheduler_id=scheduler_id,
        scheduler_name=scheduler_name,
        server=server,
        marzban=marzban,
        prometheus=samples,
        users=users,
    )

    if use_cache and PUSH_METRICS_CACHE_TTL > 0:
        with _cache_lock:
            _snapshot_cache[cache_key] = (now + PUSH_METRICS_CACHE_TTL,
                                          payload.model_copy(deep=True))

    return payload


def _escape_label_value(value: str) -> str:
    return value.replace("\\", "\\\\").replace("\n", "\\n").replace('"', '\\"')


def render_prometheus_text(payload: PushMetricsPayload) -> str:
    """Render the collected samples in the Prometheus text exposition format."""
    lines = []
    emitted_help = set()
    for sample in payload.prometheus:
        if sample.name not in emitted_help:
            if sample.help:
                lines.append(f"# HELP {sample.name} {sample.help}")
            lines.append(f"# TYPE {sample.name} {sample.type}")
            emitted_help.add(sample.name)
        if sample.labels:
            label_str = ",".join(
                f'{k}="{_escape_label_value(str(v))}"' for k, v in sample.labels.items()
            )
            lines.append(f"{sample.name}{{{label_str}}} {sample.value}")
        else:
            lines.append(f"{sample.name} {sample.value}")
    return "\n".join(lines) + "\n"
