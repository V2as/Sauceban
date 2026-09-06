"""Traffic-anomaly detection for shared subscriptions.

The monitor answers one question: is a single subscription being used by more
people than it was sold for, and is that actually loading the server?

Signals come straight from the running Xray cores. `statsUserOnline` makes the
core keep the set of source IPs that currently hold connections per user, and
one `GetUsersStats` RPC per core returns all of them at once, so a sampling
tick costs one gRPC call per node plus (for the users seen online) one indexed
SELECT for their traffic counters. No log parsing, no per-user fan-out.

Precision comes from four things rather than from a big threshold:

* **subnet collapsing** — mobile carriers rotate the egress IP of a *single*
  device mid-session, so raw IP counts alarm on honest users. Counting
  distinct /24 (IPv4) and /64 (IPv6) prefixes collapses that rotation while
  genuine sharing across households still crosses prefixes.
* **simultaneity** — a device that moves visits networks one after another; a
  shared key has several networks connected *at the same instant*. The
  highest-scoring rule therefore counts networks within a single sample, not
  across the window, which is what separates a commuter from a reseller.
* **sustained hits** — a rule must fire on `min_hits` consecutive samples.
  One-off samples (dual-stack clients briefly showing an A and an AAAA
  address, Happy Eyeballs, a reconnect from a new IP) never report.
* **a load gate** — `min_traffic_rate_mbps` requires the user to actually push
  traffic before a sharing report is emitted, which is the difference between
  "shared" and "shared and costing you capacity".

All window state is in memory and bounded; nothing here writes to the
database. With monitoring disabled the module does nothing at all.
"""
import ipaddress
from collections import deque
from dataclasses import dataclass, field
from threading import Lock
from time import time
from typing import Deque, Dict, List, Optional, Tuple

from config import ANOMALY_MAX_TRACKED_USERS

# score -> severity. Fixed on purpose: thresholds are what an operator tunes,
# the severity scale is what receivers filter on and must stay comparable
# between panels.
SEVERITY_ORDER = ("low", "medium", "high", "critical")
_SEVERITY_CUTOFFS = ((75, "critical"), (55, "high"), (35, "medium"))

# a suppressed user is re-reported before its cooldown expires only if the
# situation got clearly worse
_ESCALATION_DELTA = 15

# Raw address counts are noisy: carrier NAT hands one phone several addresses
# out of the same pool, and a dual-stack client contributes both an A and an
# AAAA address. Both stay inside a single /24 or /64, so the IP-count rules
# only fire once the addresses span at least this many networks. Sharing
# between households always crosses that line; one device never does.
_MIN_NETWORKS_FOR_IP_RULES = 2

# how fast the per-user traffic baseline follows reality; deliberately slow so
# an ongoing anomaly cannot become the new normal within its own window
_BASELINE_ALPHA = 0.05
_BASELINE_WARMUP = 10


def parse_email(email: str) -> Tuple[Optional[int], str]:
    """Split the Xray email (`{user_id}.{username}`) into its two parts."""
    prefix, _, rest = email.partition(".")
    if rest and prefix.isdigit():
        return int(prefix), rest
    return None, email


def network_of(ip: str) -> str:
    """Group an address with its neighbours: /24 for IPv4, /64 for IPv6."""
    try:
        address = ipaddress.ip_address(ip)
    except ValueError:
        return ip
    prefix = 24 if address.version == 4 else 64
    return str(ipaddress.ip_network(f"{ip}/{prefix}", strict=False))


def _is_local(ip: str) -> bool:
    try:
        address = ipaddress.ip_address(ip)
    except ValueError:
        return False
    return address.is_loopback or address.is_private


@dataclass
class Observation:
    """One source IP seen for one user during a sampling tick."""

    ip: str
    last_seen: float
    node: str


@dataclass
class Reason:
    rule: str
    value: float
    threshold: float


@dataclass
class Finding:
    email: str
    username: str
    user_id: Optional[int]
    severity: str
    score: int
    reasons: List[Reason]
    distinct_ips: int
    distinct_subnets: int
    peak_concurrent_ips: int
    peak_concurrent_networks: int
    ips: List[Dict[str, object]]
    subnets: List[str]
    nodes: List[str]
    window_traffic_bytes: int
    traffic_rate_bytes_per_sec: float
    baseline_rate_bytes_per_sec: float
    traffic_ratio: float
    samples: int
    hits: int
    first_seen_at: float
    last_seen_at: float
    suppressed: bool = False


@dataclass
class _UserState:
    username: str
    user_id: Optional[int]
    ips: Dict[str, float] = field(default_factory=dict)
    nodes: Dict[str, float] = field(default_factory=dict)
    # (sample ts, IPs in that sample, networks in that sample)
    concurrency: Deque[Tuple[float, int, int]] = field(default_factory=deque)
    traffic: Deque[Tuple[float, int]] = field(default_factory=deque)
    baseline: float = 0.0
    baseline_samples: int = 0
    hits: int = 0
    first_seen: float = 0.0
    last_seen: float = 0.0


class AnomalyMonitor:
    """Sliding-window view of who is online, from where, and how hard."""

    def __init__(self):
        self._lock = Lock()
        self._users: Dict[str, _UserState] = {}
        # kept apart from _UserState so a user going offline does not reset
        # its cooldown: email -> (reported_at, score)
        self._cooldowns: Dict[str, Tuple[float, int]] = {}
        self.ip_source: str = "unknown"
        self.last_sample_at: Optional[float] = None
        self.last_error: Optional[str] = None
        self.nodes_sampled: List[str] = []
        self.nodes_failed: List[str] = []
        self.users_online: int = 0

    # -- ingestion ---------------------------------------------------------

    def add_sample(
        self,
        observations: Dict[str, List[Observation]],
        window_seconds: int,
        ip_source: str,
        nodes_sampled: List[str],
        nodes_failed: List[str],
        error: Optional[str] = None,
        now: Optional[float] = None,
    ) -> None:
        now = now or time()
        with self._lock:
            self.ip_source = ip_source
            self.last_sample_at = now
            self.last_error = error
            self.nodes_sampled = nodes_sampled
            self.nodes_failed = nodes_failed
            self.users_online = len(observations)

            for email, seen in observations.items():
                state = self._users.get(email)
                if state is None:
                    user_id, username = parse_email(email)
                    state = _UserState(username=username, user_id=user_id, first_seen=now)
                    self._users[email] = state

                for observation in seen:
                    last_seen = observation.last_seen or now
                    state.ips[observation.ip] = max(
                        state.ips.get(observation.ip, 0.0), last_seen
                    )
                    state.nodes[observation.node] = now

                sample_ips = {o.ip for o in seen}
                state.concurrency.append((
                    now, len(sample_ips), len({network_of(ip) for ip in sample_ips})
                ))
                state.last_seen = now
                if not state.first_seen:
                    state.first_seen = now

            self._prune(now, window_seconds)

    def add_traffic(self, traffic: Dict[int, int], window_seconds: int,
                    now: Optional[float] = None) -> None:
        """Feed cumulative `users.used_traffic` counters for online users."""
        now = now or time()
        with self._lock:
            for state in self._users.values():
                if state.user_id is None or state.user_id not in traffic:
                    continue
                total = int(traffic[state.user_id])
                if state.traffic and total < state.traffic[-1][1]:
                    # usage was reset (plan reset / manual) — start over
                    state.traffic.clear()
                state.traffic.append((now, total))
                while state.traffic and state.traffic[0][0] < now - window_seconds:
                    state.traffic.popleft()

                rate = self._rate(state)
                if rate is not None:
                    state.baseline = (
                        rate if state.baseline_samples == 0
                        else _BASELINE_ALPHA * rate + (1 - _BASELINE_ALPHA) * state.baseline
                    )
                    state.baseline_samples += 1

    def _prune(self, now: float, window_seconds: int) -> None:
        cutoff = now - window_seconds
        stale = []
        for email, state in self._users.items():
            state.ips = {ip: seen for ip, seen in state.ips.items() if seen >= cutoff}
            state.nodes = {n: seen for n, seen in state.nodes.items() if seen >= cutoff}
            while state.concurrency and state.concurrency[0][0] < cutoff:
                state.concurrency.popleft()
            while state.traffic and state.traffic[0][0] < cutoff:
                state.traffic.popleft()
            if not state.ips and state.last_seen < cutoff:
                stale.append(email)
        for email in stale:
            del self._users[email]

        for email, (reported_at, _) in list(self._cooldowns.items()):
            if reported_at < now - 86400:
                del self._cooldowns[email]

        # hard memory ceiling: keep the most recently seen users
        overflow = len(self._users) - ANOMALY_MAX_TRACKED_USERS
        if overflow > 0:
            for email, _ in sorted(
                self._users.items(), key=lambda kv: kv[1].last_seen
            )[:overflow]:
                del self._users[email]

    # -- evaluation --------------------------------------------------------

    @staticmethod
    def _rate(state: _UserState) -> Optional[float]:
        if len(state.traffic) < 2:
            return None
        (first_ts, first_bytes), (last_ts, last_bytes) = state.traffic[0], state.traffic[-1]
        span = last_ts - first_ts
        if span <= 0:
            return None
        return max(0.0, (last_bytes - first_bytes) / span)

    def evaluate(self, settings, mutate: bool = True,
                 now: Optional[float] = None) -> List[Finding]:
        """Score every tracked user against the configured thresholds.

        `settings` is any object exposing the anomaly settings fields (the
        SQLAlchemy row and the pydantic model both do). With `mutate=False`
        neither the sustained-hit counters nor the cooldowns are touched, so
        the API can preview the current state without affecting delivery.
        """
        now = now or time()
        findings: List[Finding] = []

        with self._lock:
            for email, state in self._users.items():
                finding = self._evaluate_user(email, state, settings, now, mutate)
                if finding is not None:
                    findings.append(finding)

        findings.sort(key=lambda f: f.score, reverse=True)
        return findings

    def _evaluate_user(self, email: str, state: _UserState, settings,
                       now: float, mutate: bool) -> Optional[Finding]:
        distinct_ips = len(state.ips)
        if not distinct_ips:
            if mutate:
                state.hits = 0
            return None

        subnets = sorted({network_of(ip) for ip in state.ips})
        peak_concurrent = max((ips for _, ips, _ in state.concurrency), default=0)
        peak_networks = max((nets for _, _, nets in state.concurrency), default=0)
        rate = self._rate(state) or 0.0
        window_bytes = 0
        if len(state.traffic) >= 2:
            window_bytes = max(0, state.traffic[-1][1] - state.traffic[0][1])
        baseline = state.baseline if state.baseline_samples >= _BASELINE_WARMUP else 0.0
        ratio = (rate / baseline) if baseline > 0 else 0.0

        reasons: List[Reason] = []
        score = 0
        multi_network = len(subnets) >= _MIN_NETWORKS_FOR_IP_RULES

        # networks online at the same instant: the strongest evidence, so it
        # carries the most weight
        if settings.max_concurrent_networks \
                and peak_networks > settings.max_concurrent_networks:
            excess = peak_networks - settings.max_concurrent_networks
            score += 25 + 15 * excess
            reasons.append(Reason("concurrent_networks", peak_networks,
                                  settings.max_concurrent_networks))

        # networks anywhere in the window: sensitive, but a commuting phone
        # trips it too, so it scores low on its own
        if settings.max_subnets and len(subnets) > settings.max_subnets:
            excess = len(subnets) - settings.max_subnets
            score += 15 + 8 * excess
            reasons.append(Reason("distinct_subnets", len(subnets), settings.max_subnets))

        # raw address count: coarsest of the three
        if multi_network and settings.max_ips and distinct_ips > settings.max_ips:
            excess = distinct_ips - settings.max_ips
            score += 10 + 5 * excess
            reasons.append(Reason("distinct_ips", distinct_ips, settings.max_ips))

        if settings.traffic_spike_ratio and ratio >= settings.traffic_spike_ratio:
            score += 15 + min(20, int(5 * (ratio - settings.traffic_spike_ratio)))
            reasons.append(Reason("traffic_spike", round(ratio, 2),
                                  settings.traffic_spike_ratio))

        if not reasons:
            if mutate:
                state.hits = 0
            return None

        # load gate: sharing only matters when it actually costs capacity
        rate_mbps = rate * 8 / 1_000_000
        if settings.min_traffic_rate_mbps:
            if rate_mbps < settings.min_traffic_rate_mbps:
                if mutate:
                    state.hits = 0
                return None
            score += 10
            reasons.append(Reason("traffic_rate_mbps", round(rate_mbps, 2),
                                  settings.min_traffic_rate_mbps))

        hits = state.hits + 1
        if mutate:
            state.hits = hits
        if hits < max(1, settings.min_hits):
            return None

        score = max(1, min(100, score))
        severity = "low"
        for cutoff, name in _SEVERITY_CUTOFFS:
            if score >= cutoff:
                severity = name
                break

        suppressed = False
        previous = self._cooldowns.get(email)
        if previous and now - previous[0] < settings.cooldown_seconds \
                and score <= previous[1] + _ESCALATION_DELTA:
            suppressed = True
        elif mutate:
            self._cooldowns[email] = (now, score)

        ips: List[Dict[str, object]] = []
        if settings.include_ips:
            ordered = sorted(state.ips.items(), key=lambda kv: kv[1], reverse=True)
            ips = [
                {"ip": ip, "last_seen": int(seen), "network": network_of(ip)}
                for ip, seen in ordered[: max(1, settings.max_ips_in_report)]
            ]

        return Finding(
            email=email,
            username=state.username,
            user_id=state.user_id,
            severity=severity,
            score=score,
            reasons=reasons,
            distinct_ips=distinct_ips,
            distinct_subnets=len(subnets),
            peak_concurrent_ips=peak_concurrent,
            peak_concurrent_networks=peak_networks,
            ips=ips,
            subnets=subnets[: max(1, settings.max_ips_in_report)],
            nodes=sorted(state.nodes),
            window_traffic_bytes=window_bytes,
            traffic_rate_bytes_per_sec=round(rate, 2),
            baseline_rate_bytes_per_sec=round(baseline, 2),
            traffic_ratio=round(ratio, 2),
            samples=len(state.concurrency),
            hits=hits,
            first_seen_at=state.first_seen,
            last_seen_at=state.last_seen,
            suppressed=suppressed,
        )

    # -- introspection -----------------------------------------------------

    def status(self) -> dict:
        """Sampler health, for the API/UI and for the push payload."""
        with self._lock:
            observed = [ip for state in self._users.values() for ip in state.ips]
            warnings = []
            if observed and all(_is_local(ip) for ip in observed):
                warnings.append(
                    "every observed source IP is private or loopback — the core "
                    "sees a reverse proxy, enable the PROXY protocol on the "
                    "inbound to get real client addresses"
                )
            if self.ip_source == "unavailable":
                warnings.append(
                    "this Xray core does not report per-user online IPs, so "
                    "sharing cannot be detected — update the core to v25.2.18 "
                    "or newer (v26.4.13+ answers in a single call)"
                )
            return {
                "ip_source": self.ip_source,
                "last_sample_at": self.last_sample_at,
                "last_error": self.last_error,
                "nodes_sampled": list(self.nodes_sampled),
                "nodes_failed": list(self.nodes_failed),
                "tracked_users": len(self._users),
                "users_online": self.users_online,
                "warnings": warnings,
            }

    def user_state(self, username: str) -> Optional[dict]:
        with self._lock:
            for email, state in self._users.items():
                if state.username.lower() != username.lower():
                    continue
                return {
                    "email": email,
                    "username": state.username,
                    "distinct_ips": len(state.ips),
                    "distinct_subnets": len({network_of(ip) for ip in state.ips}),
                    "peak_concurrent_ips": max(
                        (ips for _, ips, _ in state.concurrency), default=0
                    ),
                    "peak_concurrent_networks": max(
                        (nets for _, _, nets in state.concurrency), default=0
                    ),
                    "ips": [
                        {"ip": ip, "last_seen": int(seen), "network": network_of(ip)}
                        for ip, seen in sorted(
                            state.ips.items(), key=lambda kv: kv[1], reverse=True
                        )
                    ],
                    "nodes": sorted(state.nodes),
                    "traffic_rate_bytes_per_sec": round(self._rate(state) or 0.0, 2),
                    "baseline_rate_bytes_per_sec": round(state.baseline, 2),
                    "samples": len(state.concurrency),
                    "hits": state.hits,
                    "first_seen_at": state.first_seen,
                    "last_seen_at": state.last_seen,
                }
        return None

    def online_user_ids(self) -> List[int]:
        with self._lock:
            return [s.user_id for s in self._users.values() if s.user_id is not None]

    def reset(self) -> None:
        """Drop all window state (used when monitoring is switched off)."""
        with self._lock:
            self._users.clear()
            self._cooldowns.clear()
            self.ip_source = "unknown"
            self.last_sample_at = None
            self.last_error = None
            self.nodes_sampled = []
            self.nodes_failed = []
            self.users_online = 0


monitor = AnomalyMonitor()
