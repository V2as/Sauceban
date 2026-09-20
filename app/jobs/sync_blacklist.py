"""Keeps the kernel's bandwidth caps in sync with the blacklist table.

A cap is stored against a user, but traffic control can only recognise an
address, so every tick answers one question: which source addresses do the
capped users currently connect from? Those come from the core's online-IP
stats — the same RPCs the anomaly monitor uses — and are handed to
:mod:`app.utils.shaper`, which turns them into `tc` classes and filters.

Only the local core is queried: a user connected through a remote node does
not send a byte through this host, so there is nothing here to shape (caps on
nodes would need an agent running on the node itself).

Caps written by the anomaly monitor carry an expiry; this job is what lifts
them, so they run out even while monitoring is switched off.

The same tick reconciles the panel-wide cap every address gets on its own
(:mod:`app.utils.global_limiter`). That one needs no addresses at all — the
kernel keeps a bucket per address — so all it costs here is reading the
setting and comparing it with what is installed.

Cost of a tick with an empty blacklist is two indexed SELECTs. With capped
users it adds one gRPC call, plus one call per capped user that is online on
cores too old for the bulk RPC. Rules are only rewritten when the set of
(address, cap) pairs actually changed.
"""
from datetime import datetime as dt
from datetime import timedelta as td
from time import time
from typing import Dict, List, Optional, Tuple

from app import logger, scheduler, xray
from app.db import GetDB, Session, crud
from app.utils.global_limiter import global_limiter
from app.utils.shaper import UserShape, shaper
from config import (BLACKLIST_ENFORCE, BLACKLIST_IP_TTL,
                    BLACKLIST_STATS_TIMEOUT, JOB_SYNC_BLACKLIST_INTERVAL)
from xray_api import exc as xray_exc

SYNC_JOB_ID = "sync_blacklist"
RUN_NOW_JOB_ID = "sync_blacklist_now"

# user id -> {source ip: last seen at}. Addresses linger for BLACKLIST_IP_TTL
# so a user that goes quiet between samples is not un-shaped and re-shaped.
_ips: Dict[int, Dict[str, float]] = {}
_state: Dict[str, object] = {
    "last_sync_at": None,
    "ip_source": "unavailable",
    "last_error": None,
}


def _collect(emails: Dict[str, int]) -> Tuple[str, Dict[int, List[str]], Optional[str]]:
    """Online addresses of the capped users, keyed by user id.

    Walks the same ladder of RPCs as the anomaly monitor, since each landed in
    a different Xray release: the bulk call first, then "who is online" plus a
    probe per capped user that shows up there, and finally a probe for every
    capped user.
    """
    if not xray.core.started:
        return "unavailable", {}, None

    api = xray.api
    try:
        users = api.get_users_online_stats(timeout=BLACKLIST_STATS_TIMEOUT)
        found: Dict[int, List[str]] = {}
        for user in users:
            user_id = emails.get(user.email)
            if user_id is not None and user.ips:
                found[user_id] = [entry.ip for entry in user.ips]
        return "bulk", found, None
    except xray_exc.NotSupportedError:
        pass
    except Exception as err:
        return "unavailable", {}, str(err)[:300]

    targets = list(emails)
    try:
        online = set(api.get_all_online_users(timeout=BLACKLIST_STATS_TIMEOUT))
        targets = [email for email in emails if email in online]
    except xray_exc.NotSupportedError:
        pass  # older core: probe every capped user instead
    except Exception as err:
        logger.debug(f"blacklist: online-user list failed: {err}")

    found = {}
    answered = False
    for email in targets:
        try:
            ips = api.get_user_online_ips(email, timeout=BLACKLIST_STATS_TIMEOUT)
        except xray_exc.NotSupportedError:
            return "unavailable", {}, None
        except Exception:
            continue
        answered = True
        if ips:
            found[emails[email]] = [entry.ip for entry in ips]

    if not answered and targets:
        return "unavailable", {}, None
    return "probe", found, None


def _remember(fresh: Dict[int, List[str]], capped: List[int]) -> Dict[int, List[str]]:
    """Merge this sample into the TTL-backed view of who connects from where."""
    now = time()
    for user_id in list(_ips):
        if user_id not in capped:
            del _ips[user_id]

    for user_id, ips in fresh.items():
        seen = _ips.setdefault(user_id, {})
        for ip in ips:
            seen[ip] = now

    known: Dict[int, List[str]] = {}
    for user_id, seen in _ips.items():
        for ip in [ip for ip, last in seen.items() if now - last > BLACKLIST_IP_TTL]:
            del seen[ip]
        if seen:
            known[user_id] = sorted(seen)
    return known


def status() -> dict:
    """What the API reports about enforcement."""
    info = shaper.status()
    info.update({
        "enforce": BLACKLIST_ENFORCE,
        "ip_source": _state["ip_source"],
        "last_sync_at": _state["last_sync_at"],
    })
    if not info.get("last_error"):
        info["last_error"] = _state["last_error"]
    return info


def shaped_ips() -> Dict[int, List[str]]:
    """Addresses currently being shaped, keyed by user id."""
    now = time()
    return {
        user_id: sorted(ip for ip, last in seen.items() if now - last <= BLACKLIST_IP_TTL)
        for user_id, seen in _ips.items()
    }


def _read_global_limit(db: Session) -> Optional[Tuple[bool, int]]:
    """The panel-wide cap as (enabled, mbps), or None when it cannot be read.

    Guarded on its own so a database that has not been migrated yet — no
    `bandwidth_settings` table — still gets its per-user caps reconciled.
    """
    try:
        settings = crud.get_bandwidth_settings(db)
        return bool(settings.global_enabled), int(settings.global_mbps)
    except Exception as err:
        logger.debug(f"global limit: settings unavailable: {err}")
        return None


def run_sync() -> None:
    """One reconciliation pass: read the caps, find the IPs, apply the rules."""
    global_limit = None
    try:
        with GetDB() as db:
            active = crud.get_active_blacklist(db)
            # a cap installed by the anomaly monitor stops being enforced the
            # moment it expires; the row is deleted in the same pass, and only
            # when there is something to delete, so an idle tick stays at one
            # SELECT
            now = dt.utcnow()
            if any(until is not None and until <= now for _, _, _, until in active):
                lifted = crud.expire_anomaly_throttles(db)
                if lifted:
                    logger.info(
                        "Anomaly throttle expired for " + ", ".join(sorted(lifted))
                    )
                active = [
                    entry for entry in active
                    if entry[3] is None or entry[3] > now
                ]
            global_limit = _read_global_limit(db)
    except Exception as err:
        # table missing (migrations not run yet) or database hiccup
        logger.debug(f"blacklist sync skipped: {err}")
        return

    _state["last_sync_at"] = time()

    if not BLACKLIST_ENFORCE:
        _state["ip_source"] = "unavailable"
        # the switch covers both mechanisms; the call also removes a table left
        # behind by a previous process and then costs nothing
        global_limiter.apply(False, 0)
        return

    # the kernel holds the per-address buckets itself, so this is a no-op until
    # the setting changes — no addresses are collected and no rules rewritten
    if global_limit is not None:
        global_limiter.apply(*global_limit)

    if not active:
        _ips.clear()
        _state["ip_source"] = "unavailable"
        shaper.apply([])
        return

    emails = {f"{user_id}.{username}": user_id for user_id, username, _, _ in active}
    source, fresh, error = _collect(emails)
    _state["ip_source"] = source
    _state["last_error"] = error
    if error:
        logger.debug(f"blacklist: online IPs unavailable: {error}")

    known = _remember(fresh, [user_id for user_id, _, _, _ in active])

    shaper.apply([
        UserShape(
            user_id=user_id,
            username=username,
            limit_mbps=limit_mbps,
            ips=tuple(known.get(user_id, ())),
        )
        for user_id, username, limit_mbps, _ in active
    ])


def request_sync() -> None:
    """Reconcile as soon as possible, without blocking the caller.

    Mutations come in through the API, where waiting for a gRPC round trip and
    a `tc` run would show up as request latency; the job queue absorbs that.
    """
    try:
        scheduler.add_job(
            run_sync, "date",
            run_date=dt.utcnow() + td(seconds=1),
            id=RUN_NOW_JOB_ID,
            replace_existing=True,
            misfire_grace_time=30,
        )
    except Exception as err:
        logger.debug(f"requested blacklist sync failed: {err}")


logger.info("Bandwidth blacklist manager started")
scheduler.add_job(
    run_sync, "interval",
    seconds=JOB_SYNC_BLACKLIST_INTERVAL,
    id=SYNC_JOB_ID,
    replace_existing=True,
    coalesce=True,
    max_instances=1,
    next_run_time=dt.utcnow() + td(seconds=10),
)
