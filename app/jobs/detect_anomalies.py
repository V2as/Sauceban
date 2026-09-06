"""Traffic-anomaly sampler and reporter.

One APScheduler job takes a snapshot of who is online and from which source
IPs, feeds it to the monitor in :mod:`app.utils.anomaly`, and pushes whatever
the monitor reports to the configured webhooks. A reconciler keeps that job in
sync with the `anomaly_settings` row, so the monitor can be switched on and
off, and its interval changed, at runtime through the API / CLI / dashboard.

Nothing runs unless monitoring is enabled: with `is_enabled` false the sampler
job is removed and the window state dropped.

A tick costs one gRPC call per core/node plus one indexed SELECT for the
traffic counters of the users seen online. Cores too old for the bulk
`GetUsersStats` RPC are probed one user at a time, capped at
`ANOMALY_PROBE_LIMIT` and ordered by traffic delta so the heaviest users —
the ones that can actually overload the server — are always covered.
"""
import socket
import time
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime as dt
from datetime import timedelta as td
from typing import Dict, List, Optional, Tuple

from app import logger, scheduler, xray
from app.db import GetDB, crud
from app.db.models import Node
from app.models.anomaly import (AnomalyClient, AnomalyEvidence, AnomalyIp,
                                AnomalyMonitorInfo, AnomalyReason,
                                AnomalyRecord, AnomalyReport,
                                AnomalySchedulerResponse,
                                AnomalySettingsResponse, AnomalySummary,
                                severity_rank)
from app.utils.anomaly import Finding, Observation, monitor
from config import (ANOMALY_PROBE_LIMIT, ANOMALY_STATS_TIMEOUT,
                    JOB_SYNC_ANOMALY_MONITOR_INTERVAL)
from xray_api import exc as xray_exc

SAMPLE_JOB_ID = "anomaly_sample"
SYNC_JOB_ID = "sync_anomaly_monitor"

USER_AGENT = "Marzban-AnomalyMonitor/1.0"

# how many anomalies a single target may accumulate while its webhook is
# unreachable or throttled; the lowest scores are dropped first
MAX_PENDING_PER_TARGET = 200

# the interval currently registered for the sampler, to detect changes
_state: Dict[str, Optional[int]] = {"interval": None}
# node id -> display name, refreshed by the reconciler
_node_names: Dict[int, str] = {}
# scheduler id -> unix ts of its last delivery attempt
_last_push: Dict[int, float] = {}
# scheduler id -> {username: finding} still waiting to be delivered
_pending: Dict[int, Dict[str, Finding]] = {}
# user id -> used_traffic, only used by the per-user probe fallback
_probe_traffic: Dict[int, int] = {}


def _node_label(node_id: Optional[int]) -> str:
    if node_id is None:
        return "local"
    return _node_names.get(node_id) or f"node-{node_id}"


def _collect(api, label: str, probe_emails: List[str]
             ) -> Tuple[str, Dict[str, List[Observation]], Optional[str]]:
    """Online IPs per user for one core. Returns (source, observations, error)."""
    now = time.time()
    try:
        users = api.get_users_online_stats(timeout=ANOMALY_STATS_TIMEOUT)
        return "bulk", {
            user.email: [
                Observation(ip=entry.ip, last_seen=entry.last_seen or now, node=label)
                for entry in user.ips
            ]
            for user in users if user.ips
        }, None
    except xray_exc.NotSupportedError:
        pass  # older core: fall back to probing individual users
    except xray_exc.XrayError as err:
        return "error", {}, str(getattr(err, "details", err))[:300]
    except Exception as err:
        return "error", {}, str(err)[:300]

    if not probe_emails:
        return "unavailable", {}, None

    observations: Dict[str, List[Observation]] = {}
    for email in probe_emails:
        try:
            ips = api.get_user_online_ips(email, timeout=ANOMALY_STATS_TIMEOUT)
        except xray_exc.NotSupportedError:
            return "unavailable", {}, None
        except Exception:
            continue
        if ips:
            observations[email] = [
                Observation(ip=entry.ip, last_seen=entry.last_seen or now, node=label)
                for entry in ips
            ]
    return "probe", observations, None


def _probe_candidates(settings) -> List[str]:
    """Emails worth probing on cores without the bulk RPC.

    Recently online users ranked by how much traffic they moved since the
    previous tick, so the probe budget goes to the heaviest accounts.
    """
    since = dt.utcnow() - td(seconds=max(settings.sample_interval * 3, 120))
    try:
        with GetDB() as db:
            rows = crud.get_recently_online_users(
                db, since, limit=max(ANOMALY_PROBE_LIMIT * 5, 500)
            )
    except Exception as err:
        logger.debug(f"anomaly probe candidates unavailable: {err}")
        return []

    ranked = sorted(
        rows,
        key=lambda row: row[2] - _probe_traffic.get(row[0], row[2]),
        reverse=True,
    )
    _probe_traffic.clear()
    _probe_traffic.update({row[0]: row[2] for row in rows})
    return [f"{user_id}.{username}" for user_id, username, _ in ranked[:ANOMALY_PROBE_LIMIT]]


def _sample(settings) -> None:
    """Take one snapshot of every core and feed it to the monitor."""
    apis = {}
    if xray.core.started:
        apis[None] = xray.api
    for node_id, node in list(xray.nodes.items()):
        if node.connected and node.started:
            apis[node_id] = node.api

    probe_emails: List[str] = []
    if monitor.ip_source in ("probe", "unavailable"):
        # only pay for the candidate query while actually in the fallback path
        probe_emails = _probe_candidates(settings)

    with ThreadPoolExecutor(max_workers=10) as executor:
        futures = {
            node_id: executor.submit(_collect, api, _node_label(node_id), probe_emails)
            for node_id, api in apis.items()
        }
        results = {node_id: future.result() for node_id, future in futures.items()}

    merged: Dict[str, List[Observation]] = {}
    sampled, failed, sources, errors = [], [], set(), []
    for node_id, (source, observations, error) in results.items():
        label = _node_label(node_id)
        if source == "error":
            failed.append(label)
            if error:
                errors.append(f"{label}: {error}")
            continue
        sampled.append(label)
        sources.add(source)
        for email, seen in observations.items():
            merged.setdefault(email, []).extend(seen)

    if "bulk" in sources:
        ip_source = "bulk"
    elif "probe" in sources:
        ip_source = "probe"
    elif sources:
        ip_source = "unavailable"
    else:
        ip_source = monitor.ip_source if failed else "unavailable"

    monitor.add_sample(
        merged,
        window_seconds=settings.window_seconds,
        ip_source=ip_source,
        nodes_sampled=sampled,
        nodes_failed=failed,
        error="; ".join(errors)[:500] or None,
    )

    user_ids = monitor.online_user_ids()
    if user_ids:
        try:
            with GetDB() as db:
                traffic = crud.get_users_traffic(db, user_ids)
            monitor.add_traffic(traffic, window_seconds=settings.window_seconds)
        except Exception as err:
            logger.debug(f"anomaly traffic sampling failed: {err}")


def monitor_info(settings) -> AnomalyMonitorInfo:
    status = monitor.status()
    return AnomalyMonitorInfo(
        is_enabled=bool(settings.is_enabled),
        ip_source=status["ip_source"],
        sample_interval=settings.sample_interval,
        window_seconds=settings.window_seconds,
        thresholds={
            "max_concurrent_networks": settings.max_concurrent_networks,
            "max_subnets": settings.max_subnets,
            "max_ips": settings.max_ips,
            "min_hits": settings.min_hits,
            "min_traffic_rate_mbps": settings.min_traffic_rate_mbps,
            "traffic_spike_ratio": settings.traffic_spike_ratio,
            "cooldown_seconds": settings.cooldown_seconds,
        },
        last_sample_at=status["last_sample_at"],
        last_error=status["last_error"],
        nodes_sampled=status["nodes_sampled"],
        nodes_failed=status["nodes_failed"],
        tracked_users=status["tracked_users"],
        users_online=status["users_online"],
        warnings=status["warnings"],
    )


def build_report(settings, findings: List[Finding],
                 scheduler_id: Optional[int] = None,
                 scheduler_name: Optional[str] = None,
                 collected_in_ms: float = 0.0) -> AnomalyReport:
    """Turn findings into the payload that goes out over the webhook."""
    clients: Dict[str, dict] = {}
    if findings:
        try:
            with GetDB() as db:
                clients = crud.get_anomaly_clients(db, [f.username for f in findings])
        except Exception as err:
            logger.debug(f"anomaly client lookup failed: {err}")

    records, by_severity, suppressed = [], {}, 0
    now = time.time()
    for finding in findings:
        if finding.suppressed:
            suppressed += 1
        by_severity[finding.severity] = by_severity.get(finding.severity, 0) + 1
        client = clients.get(finding.username, {})
        records.append(AnomalyRecord(
            username=finding.username,
            severity=finding.severity,
            score=finding.score,
            reasons=[
                AnomalyReason(rule=r.rule, value=r.value, threshold=r.threshold)
                for r in finding.reasons
            ],
            detected_at=now,
            suppressed=finding.suppressed,
            evidence=AnomalyEvidence(
                distinct_ips=finding.distinct_ips,
                distinct_subnets=finding.distinct_subnets,
                peak_concurrent_ips=finding.peak_concurrent_ips,
                peak_concurrent_networks=finding.peak_concurrent_networks,
                ips=[AnomalyIp(**ip) for ip in finding.ips],
                subnets=finding.subnets,
                nodes=finding.nodes,
                window_traffic_bytes=finding.window_traffic_bytes,
                traffic_rate_bytes_per_sec=finding.traffic_rate_bytes_per_sec,
                traffic_rate_mbps=round(
                    finding.traffic_rate_bytes_per_sec * 8 / 1_000_000, 3
                ),
                baseline_rate_bytes_per_sec=finding.baseline_rate_bytes_per_sec,
                traffic_ratio=finding.traffic_ratio,
                samples=finding.samples,
                hits=finding.hits,
                first_seen_at=finding.first_seen_at,
                last_seen_at=finding.last_seen_at,
            ),
            client=AnomalyClient(
                username=finding.username,
                email=finding.email,
                user_id=client.get("user_id", finding.user_id),
                status=client.get("status"),
                used_traffic=client.get("used_traffic", 0),
                lifetime_used_traffic=client.get("lifetime_used_traffic", 0),
                data_limit=client.get("data_limit"),
                data_limit_reset_strategy=client.get("data_limit_reset_strategy"),
                expire=client.get("expire"),
                online_at=client.get("online_at"),
                created_at=client.get("created_at"),
                sub_updated_at=client.get("sub_updated_at"),
                sub_last_user_agent=client.get("sub_last_user_agent"),
                admin=client.get("admin"),
                note=client.get("note"),
            ),
        ))

    return AnomalyReport(
        timestamp=now,
        collected_in_ms=collected_in_ms,
        instance=socket.gethostname(),
        scheduler_id=scheduler_id,
        scheduler_name=scheduler_name,
        monitor=monitor_info(settings),
        summary=AnomalySummary(
            anomalies_total=len(records),
            suppressed_total=suppressed,
            by_severity=by_severity,
            max_score=max((f.score for f in findings), default=0),
        ),
        anomalies=records,
    )


def _queue(scheduler_id: int, findings: List[Finding]) -> None:
    queue = _pending.setdefault(scheduler_id, {})
    for finding in findings:
        previous = queue.get(finding.username)
        if previous is None or finding.score >= previous.score:
            queue[finding.username] = finding
    overflow = len(queue) - MAX_PENDING_PER_TARGET
    if overflow > 0:
        for username, _ in sorted(queue.items(), key=lambda kv: kv[1].score)[:overflow]:
            del queue[username]


def deliver_report(dbscheduler, settings, findings: List[Finding],
                   collected_in_ms: float = 0.0) -> Tuple[bool, Optional[int], Optional[str]]:
    """Push one report to one target and record the outcome."""
    from app.jobs.send_push_metrics import deliver

    payload = build_report(
        settings, findings,
        scheduler_id=dbscheduler.id,
        scheduler_name=dbscheduler.name,
        collected_in_ms=collected_in_ms,
    )
    success, status_code, error = deliver(
        dbscheduler.webhook_url, dbscheduler.secret_key, payload,
        user_agent=USER_AGENT,
    )
    with GetDB() as db:
        crud.record_anomaly_scheduler_run(
            db, dbscheduler.id, success, status_code, error, len(findings)
        )
    return success, status_code, error


def _push(settings, findings: List[Finding]) -> None:
    """Fan the reportable findings out to every enabled webhook target."""
    try:
        with GetDB() as db:
            schedulers = [
                AnomalySchedulerResponse.model_validate(s)
                for s in crud.get_anomaly_schedulers(db)
            ]
    except Exception as err:
        logger.debug(f"anomaly schedulers unavailable: {err}")
        return

    live_ids = {s.id for s in schedulers}
    for scheduler_id in list(_pending):
        if scheduler_id not in live_ids:
            del _pending[scheduler_id]

    reportable = [f for f in findings if not f.suppressed]
    now = time.time()

    for dbscheduler in schedulers:
        if not dbscheduler.is_enabled:
            continue

        floor = severity_rank(dbscheduler.min_severity)
        _queue(dbscheduler.id, [
            f for f in reportable if severity_rank(f.severity) >= floor
        ])
        queued = list(_pending.get(dbscheduler.id, {}).values())

        if not queued and not dbscheduler.send_empty:
            continue
        if now - _last_push.get(dbscheduler.id, 0.0) < dbscheduler.interval:
            continue  # too soon for this target; the queue keeps the findings

        _last_push[dbscheduler.id] = now
        queued.sort(key=lambda f: f.score, reverse=True)
        success, _, error = deliver_report(dbscheduler, settings, queued)
        if success:
            _pending.pop(dbscheduler.id, None)
        else:
            logger.warning(
                f"Anomaly push '{dbscheduler.name}' (#{dbscheduler.id}) failed: {error}"
            )


def run_sample() -> None:
    """One monitoring tick: sample, evaluate, report."""
    started = time.perf_counter()
    try:
        with GetDB() as db:
            settings = AnomalySettingsResponse.model_validate(
                crud.get_anomaly_settings(db)
            )
    except Exception as err:
        logger.debug(f"anomaly settings unavailable: {err}")
        return

    if not settings.is_enabled:
        return

    _sample(settings)
    findings = monitor.evaluate(settings, mutate=True)
    if findings:
        _push(settings, findings)

    elapsed = round((time.perf_counter() - started) * 1000, 2)
    if elapsed > 2000:
        logger.debug(f"anomaly sampling took {elapsed}ms")


def sync_anomaly_monitor() -> None:
    """Reconcile the sampler job with the settings stored in the database."""
    try:
        with GetDB() as db:
            settings = crud.get_anomaly_settings(db)
            enabled = bool(settings.is_enabled)
            interval = int(settings.sample_interval)
            _node_names.clear()
            _node_names.update(dict(db.query(Node.id, Node.name).all()))
    except Exception as err:
        # table may not exist yet (before migrations) — try again next tick
        logger.debug(f"anomaly monitor sync skipped: {err}")
        return

    job = scheduler.get_job(SAMPLE_JOB_ID)

    if not enabled:
        if job is not None:
            scheduler.remove_job(SAMPLE_JOB_ID)
            monitor.reset()
            _pending.clear()
            _last_push.clear()
            _probe_traffic.clear()
        _state["interval"] = None
        return

    if job is None:
        scheduler.add_job(
            run_sample, "interval",
            seconds=interval,
            id=SAMPLE_JOB_ID,
            coalesce=True,
            max_instances=1,
            # start sampling right after being enabled instead of after a
            # full interval
            next_run_time=dt.utcnow() + td(seconds=min(interval, 5)),
        )
        _state["interval"] = interval
    elif _state.get("interval") != interval:
        scheduler.reschedule_job(SAMPLE_JOB_ID, trigger="interval", seconds=interval)
        _state["interval"] = interval


def request_sync() -> None:
    """Trigger an immediate reconciliation (called from API/CLI mutations)."""
    try:
        sync_anomaly_monitor()
    except Exception as err:
        logger.debug(f"requested anomaly sync failed: {err}")


logger.info("Traffic-anomaly monitor manager started")
scheduler.add_job(
    sync_anomaly_monitor, "interval",
    seconds=JOB_SYNC_ANOMALY_MONITOR_INTERVAL,
    id=SYNC_JOB_ID,
    replace_existing=True,
    coalesce=True,
    max_instances=1,
    next_run_time=dt.utcnow() + td(seconds=5),
)
