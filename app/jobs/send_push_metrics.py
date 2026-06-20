"""Push-statistics schedulers.

Each enabled :class:`NotificationScheduler` row in the database is mapped to an
APScheduler interval job. A lightweight reconciler keeps the live jobs in sync
with the database (new schedulers get added, disabled/deleted ones removed and
changed intervals rescheduled), so everything can be managed at runtime through
the API / CLI / dashboard without restarting Marzban.

This is fully additive: if no schedulers are configured, nothing runs.
"""
import hashlib
import hmac
import json
from datetime import datetime as dt
from datetime import timedelta as td
from typing import Optional, Tuple

from fastapi.encoders import jsonable_encoder
from requests import Session

from app import logger, scheduler
from app.db import GetDB, crud
from app.utils.metrics import collect_metrics
from config import (JOB_SYNC_PUSH_SCHEDULERS_INTERVAL, PUSH_WEBHOOK_TIMEOUT)

session = Session()

JOB_PREFIX = "push_scheduler_"
SYNC_JOB_ID = "sync_push_schedulers"

# tracks the interval currently registered for each scheduler id so we can
# detect interval changes and reschedule without restarting the whole job.
_known_intervals: dict = {}


def _job_id(scheduler_id: int) -> str:
    return f"{JOB_PREFIX}{scheduler_id}"


def deliver(webhook_url: str, secret_key: Optional[str], payload) -> Tuple[bool, Optional[int], Optional[str]]:
    """Deliver a payload to a single webhook.

    The body is serialized once to bytes so the optional HMAC-SHA256 signature
    matches exactly what is transmitted.
    """
    try:
        body = json.dumps(jsonable_encoder(payload), default=str).encode("utf-8")
    except Exception as err:
        return False, None, f"serialization error: {err}"

    headers = {
        "Content-Type": "application/json",
        "User-Agent": "Marzban-PushMetrics/1.0",
    }
    if secret_key:
        headers["X-Webhook-Secret"] = secret_key
        signature = hmac.new(secret_key.encode("utf-8"), body, hashlib.sha256).hexdigest()
        headers["X-Signature-256"] = f"sha256={signature}"

    try:
        r = session.post(webhook_url, data=body, headers=headers, timeout=PUSH_WEBHOOK_TIMEOUT)
        if r.ok:
            return True, r.status_code, None
        return False, r.status_code, f"HTTP {r.status_code}: {r.text[:300]}"
    except Exception as err:
        return False, None, str(err)[:300]


def run_push(scheduler_id: int) -> None:
    """Collect metrics and push them for a single scheduler."""
    with GetDB() as db:
        sch = crud.get_notification_scheduler(db, scheduler_id)
        if not sch or not sch.is_enabled:
            return
        webhook_url = sch.webhook_url
        secret_key = sch.secret_key
        include_users = sch.include_users
        name = sch.name

    payload = collect_metrics(
        include_users=include_users,
        scheduler_id=scheduler_id,
        scheduler_name=name,
    )
    success, status_code, error = deliver(webhook_url, secret_key, payload)

    if not success:
        logger.warning(f"Push scheduler '{name}' (#{scheduler_id}) failed: {error}")

    with GetDB() as db:
        crud.record_notification_scheduler_run(db, scheduler_id, success, status_code, error)


def sync_push_schedulers() -> None:
    """Reconcile live APScheduler jobs with the schedulers stored in the DB."""
    try:
        with GetDB() as db:
            schedulers = crud.get_notification_schedulers(db)
    except Exception as err:
        # table may not exist yet (before migrations) — try again next tick
        logger.debug(f"push scheduler sync skipped: {err}")
        return

    desired = {s.id: s.interval for s in schedulers if s.is_enabled}

    # remove jobs that should no longer exist
    for job in scheduler.get_jobs():
        if not job.id.startswith(JOB_PREFIX):
            continue
        try:
            sid = int(job.id[len(JOB_PREFIX):])
        except ValueError:
            continue
        if sid not in desired:
            scheduler.remove_job(job.id)
            _known_intervals.pop(sid, None)

    # add new jobs / reschedule changed intervals
    for sid, interval in desired.items():
        jid = _job_id(sid)
        existing = scheduler.get_job(jid)
        if existing is None:
            scheduler.add_job(
                run_push, "interval",
                seconds=interval,
                id=jid,
                args=[sid],
                coalesce=True,
                max_instances=1,
                # fire shortly after being enabled instead of after a full interval
                next_run_time=dt.utcnow() + td(seconds=min(interval, 5)),
            )
            _known_intervals[sid] = interval
        elif _known_intervals.get(sid) != interval:
            scheduler.reschedule_job(jid, trigger="interval", seconds=interval)
            _known_intervals[sid] = interval


def request_sync() -> None:
    """Trigger an immediate reconciliation (called from API/CLI mutations)."""
    try:
        sync_push_schedulers()
    except Exception as err:
        logger.debug(f"requested push sync failed: {err}")


logger.info("Push-metrics scheduler manager started")
scheduler.add_job(
    sync_push_schedulers, "interval",
    seconds=JOB_SYNC_PUSH_SCHEDULERS_INTERVAL,
    id=SYNC_JOB_ID,
    replace_existing=True,
    coalesce=True,
    max_instances=1,
    next_run_time=dt.utcnow() + td(seconds=5),
)
