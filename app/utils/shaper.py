"""Kernel-side bandwidth shaping for blacklisted users.

Xray has no per-user rate limit, so a cap has to be enforced below it, by
Linux traffic control on the interface that carries the tunnel. A user is
identified by the source addresses its connections come from — those are read
from the core's online-IP stats by :mod:`app.jobs.sync_blacklist` and handed
over here.

Layout on the interface (only touched while at least one cap is active):

    egress   htb 1:      default class 1:ffff at link speed, one class per
                         capped user, u32 filters on the destination address
                         put packets addressed to that user in its class
    ingress  ffff:       u32 filters on the source address with a policer, so
                         the user's upload is capped without the extra ifb
                         device a second shaper would need

Shaping the egress side is what actually bounds a download: every byte the
user receives leaves through this interface. The ingress side is policed
rather than shaped because queueing inbound packets would need an ifb device
and the kernel module that comes with it; dropping over-rate packets is
enough for TCP to settle at the cap.

Everything is driven through one `tc -batch` invocation per change, and a
change only happens when the desired state differs from what was applied, so
an idle panel costs one dict comparison per tick.
"""
import json
import re
import shutil
import subprocess
from dataclasses import dataclass, field
from ipaddress import ip_address
from threading import Lock
from time import time
from typing import Dict, List, Optional, Tuple

from app import logger
from config import (BLACKLIST_INTERFACE, BLACKLIST_LINK_MBPS,
                    BLACKLIST_TC_TIMEOUT)

# root qdisc handle and the minor id of the catch-all class everything that is
# not capped falls into
_ROOT = "1:"
_DEFAULT_MINOR = 0xFFFF
# minor ids for user classes start here, 0x1..0xf are left free for hand-made
# rules an operator may have added
_FIRST_MINOR = 0x10
# u32 filter priorities, one per address family and direction
_PRIO_V4 = 1
_PRIO_V6 = 2
# how long a host that cannot shape is left alone before trying again
_RETRY_UNSUPPORTED = 300

_PERMISSION_HINT = (
    "the container needs NET_ADMIN (add `cap_add: [NET_ADMIN]` to the marzban "
    "service in docker-compose.yml and recreate it)"
)


@dataclass(frozen=True)
class UserShape:
    """The cap to enforce for one user and the addresses it applies to."""

    user_id: int
    username: str
    limit_mbps: int
    ips: Tuple[str, ...] = ()


@dataclass
class _Applied:
    """What is currently installed in the kernel."""

    classes: Dict[int, int] = field(default_factory=dict)  # minor -> mbps
    # (ip, class minor, mbps), sorted; the rate is part of the key because the
    # ingress policer carries it and has to be rewritten when a cap changes
    filters: Tuple[Tuple[str, int, int], ...] = ()


def detect_interface() -> Optional[str]:
    """Interface of the IPv4 default route, read straight from procfs."""
    try:
        with open("/proc/net/route") as routes:
            next(routes)  # header
            for line in routes:
                fields = line.split()
                # destination 00000000 with the "up" flag is the default route
                if len(fields) > 3 and fields[1] == "00000000" and int(fields[3], 16) & 1:
                    return fields[0]
    except Exception as err:
        logger.debug(f"shaper: default route lookup failed: {err}")
    return None


def _police_burst(mbps: int) -> int:
    """Policer bucket in kilobytes: about 50ms worth of traffic, never tiny."""
    return max(16, int(mbps * 6.25))


class Shaper:
    """Reconciles the kernel's traffic control state with the wanted caps."""

    def __init__(self) -> None:
        self._lock = Lock()
        self._applied = _Applied()
        self._minors: Dict[int, int] = {}  # user_id -> class minor
        self._interface: Optional[str] = None
        self._installed = False
        self._last_error: Optional[str] = None
        self._last_applied_at: Optional[float] = None
        self._unsupported: Optional[str] = None
        self._unsupported_at: float = 0.0

    # -- state -------------------------------------------------------------

    def status(self) -> dict:
        with self._lock:
            return {
                "available": self._unsupported is None,
                "unavailable_reason": self._unsupported,
                "interface": self._interface or BLACKLIST_INTERFACE or None,
                "shaped_users": len(self._applied.classes),
                "shaped_ips": len(self._applied.filters),
                "last_applied_at": self._last_applied_at,
                "last_error": self._last_error,
            }

    def traffic(self) -> Dict[int, dict]:
        """Bytes and drops per capped user, keyed by user id.

        Read from the egress classes, so `sent_bytes` is what the user
        downloaded through the shaped interface and `drops` is what the cap
        cost it.
        """
        with self._lock:
            interface, minors = self._interface, dict(self._minors)
        if not interface or not minors:
            return {}

        try:
            out = subprocess.run(
                ["tc", "-s", "-j", "class", "show", "dev", interface],
                capture_output=True, text=True, timeout=BLACKLIST_TC_TIMEOUT,
            )
            classes = json.loads(out.stdout or "[]")
        except Exception as err:
            logger.debug(f"shaper: class stats unavailable: {err}")
            return {}

        by_minor = {}
        for entry in classes:
            handle = str(entry.get("handle", ""))
            if ":" not in handle:
                continue
            try:
                by_minor[int(handle.split(":")[1], 16)] = entry
            except ValueError:
                continue

        stats = {}
        for user_id, minor in minors.items():
            entry = by_minor.get(minor)
            if not entry:
                continue
            stats[user_id] = {
                "sent_bytes": int(entry.get("stats", {}).get("bytes", 0) or 0),
                "drops": int(entry.get("stats", {}).get("drops", 0) or 0),
            }
        return stats

    # -- reconciliation ----------------------------------------------------

    def apply(self, shapes: List[UserShape]) -> None:
        """Make the kernel match `shapes`; no-op when nothing changed."""
        with self._lock:
            self._apply(shapes)

    def teardown(self) -> None:
        """Remove everything this module installed."""
        with self._lock:
            self._teardown()

    def _apply(self, shapes: List[UserShape]) -> None:
        if not shapes:
            self._teardown()
            return

        if self._unsupported and time() - self._unsupported_at < _RETRY_UNSUPPORTED:
            # a box that cannot shape stays that way until it is reconfigured;
            # retry occasionally instead of on every tick
            return

        if not shutil.which("tc"):
            self._unavailable(
                "the `tc` utility is missing from the image (install iproute2)"
            )
            return

        interface = BLACKLIST_INTERFACE or self._interface or detect_interface()
        if not interface:
            self._unavailable("no default-route interface to shape")
            return
        self._interface = interface

        wanted_classes: Dict[int, int] = {}
        wanted_filters: Dict[str, Tuple[int, int]] = {}
        for shape in sorted(shapes, key=lambda s: s.limit_mbps):
            minor = self._minor_for(shape.user_id)
            wanted_classes[minor] = shape.limit_mbps
            for ip in shape.ips:
                # sorted by limit above, so the strictest cap wins an address
                # two capped users share (household NAT, shared subscription)
                wanted_filters.setdefault(ip, (minor, shape.limit_mbps))

        filters = tuple(sorted(
            (ip, minor, mbps) for ip, (minor, mbps) in wanted_filters.items()
        ))
        if (self._installed and wanted_classes == self._applied.classes
                and filters == self._applied.filters):
            return

        script: List[str] = []
        cleanup: List[str] = []

        if not self._installed:
            conflict = self._foreign_root(interface)
            if conflict:
                self._unavailable(
                    f"interface {interface} already has a `{conflict}` root qdisc; "
                    "refusing to replace another shaper"
                )
                return
            # leftovers from a previous process, if any
            cleanup += self._teardown_script(interface)
            script.append(
                f"qdisc add dev {interface} root handle 1: htb default {_DEFAULT_MINOR:x}"
            )
            script.append(
                f"class add dev {interface} parent {_ROOT} classid 1:{_DEFAULT_MINOR:x} "
                f"htb rate {BLACKLIST_LINK_MBPS}mbit ceil {BLACKLIST_LINK_MBPS}mbit "
                f"quantum 60000"
            )
            script.append(f"qdisc add dev {interface} handle ffff: ingress")

        for minor in self._applied.classes:
            if minor not in wanted_classes:
                cleanup.append(f"class del dev {interface} classid 1:{minor:x}")

        for minor, mbps in wanted_classes.items():
            verb = "change" if minor in self._applied.classes else "add"
            script.append(
                f"class {verb} dev {interface} parent {_ROOT} classid 1:{minor:x} "
                f"htb rate {mbps}mbit ceil {mbps}mbit quantum 12000"
            )
            if verb == "add":
                # fq_codel keeps a capped user's own latency sane while its
                # class is full; pfifo (the default leaf) would not
                script.append(
                    f"qdisc add dev {interface} parent 1:{minor:x} "
                    f"handle {minor:x}: fq_codel"
                )

        # filters are cheap to recreate and a partial update would need handle
        # bookkeeping for every address, so the whole chain is rewritten
        if self._installed and filters != self._applied.filters:
            cleanup += self._filter_reset_script(interface)

        for ip, minor, mbps in filters:
            script += self._filter_script(interface, ip, minor, mbps)

        if cleanup:
            self._run(cleanup, force=True)
        if self._run(script):
            self._installed = True
            self._applied = _Applied(classes=dict(wanted_classes), filters=filters)
            self._minors = {
                user_id: minor for user_id, minor in self._minors.items()
                if minor in wanted_classes
            }
            self._last_applied_at = time()

    def _teardown(self) -> None:
        if not self._installed or not self._interface:
            self._applied = _Applied()
            self._minors.clear()
            return
        self._run(self._teardown_script(self._interface), force=True)
        self._installed = False
        self._applied = _Applied()
        self._minors.clear()
        self._last_applied_at = time()

    # -- tc plumbing -------------------------------------------------------

    def _minor_for(self, user_id: int) -> int:
        minor = self._minors.get(user_id)
        if minor is not None:
            return minor
        taken = set(self._minors.values())
        minor = _FIRST_MINOR
        while minor in taken:
            minor += 1
        self._minors[user_id] = minor
        return minor

    def _filter_script(self, interface: str, ip: str, minor: int, mbps: int) -> List[str]:
        try:
            version = ip_address(ip).version
        except ValueError:
            return []

        if version == 6:
            proto, prio, match = "ipv6", _PRIO_V6, f"match ip6 {{}} {ip}/128"
        else:
            proto, prio, match = "ip", _PRIO_V4, f"match ip {{}} {ip}/32"

        return [
            # download: everything addressed to the user goes to its class
            f"filter add dev {interface} parent {_ROOT} protocol {proto} prio {prio} "
            f"u32 {match.format('dst')} flowid 1:{minor:x}",
            # upload: policed on the way in, there is no queue to shape from
            f"filter add dev {interface} parent ffff: protocol {proto} prio {prio} "
            f"u32 {match.format('src')} police rate {mbps}mbit "
            f"burst {_police_burst(mbps)}k drop flowid :1",
        ]

    def _filter_reset_script(self, interface: str) -> List[str]:
        return [
            f"filter del dev {interface} parent {parent} prio {prio}"
            for parent in (_ROOT, "ffff:")
            for prio in (_PRIO_V4, _PRIO_V6)
        ]

    def _teardown_script(self, interface: str) -> List[str]:
        return [
            f"qdisc del dev {interface} root",
            f"qdisc del dev {interface} ingress",
        ]

    def _foreign_root(self, interface: str) -> Optional[str]:
        """Name of a root qdisc we must not touch, or None if it is free.

        The kernel defaults (and the multiqueue wrappers around them) are ours
        to replace; anything else means the box is already shaped by something
        and this feature stays out of the way.
        """
        replaceable = {"pfifo_fast", "fq_codel", "fq", "mq", "mq_prio", "noqueue",
                       "pfifo", "htb"}
        try:
            out = subprocess.run(
                ["tc", "qdisc", "show", "dev", interface],
                capture_output=True, text=True, timeout=BLACKLIST_TC_TIMEOUT,
            )
        except Exception:
            return None
        for line in out.stdout.splitlines():
            match = re.match(r"qdisc (\S+) (\S+) root", line)
            if match and match.group(1) not in replaceable:
                return match.group(1)
        return None

    def _run(self, script: List[str], force: bool = False) -> bool:
        if not script:
            return True
        command = ["tc"] + (["-force"] if force else []) + ["-batch", "-"]
        payload = "\n".join(script) + "\n"
        try:
            result = subprocess.run(
                command, input=payload, capture_output=True, text=True,
                timeout=BLACKLIST_TC_TIMEOUT,
            )
        except Exception as err:
            self._fail(f"running tc failed: {err}")
            return False

        if result.returncode != 0 and not force:
            error = (result.stderr or result.stdout or "").strip()[:300]
            if "not permitted" in error.lower() or "permission denied" in error.lower():
                self._last_error = error
                self._unavailable(
                    f"tc is not allowed to change the interface: {_PERMISSION_HINT}"
                )
                return False
            self._fail(f"tc rejected the rules: {error}")
            return False

        if not force:
            self._unsupported = None
            self._last_error = None
        return True

    def _unavailable(self, reason: str) -> None:
        if self._unsupported != reason:
            logger.warning(f"Bandwidth shaping unavailable: {reason}")
        self._unsupported = reason
        self._unsupported_at = time()

    def _fail(self, message: str) -> None:
        if self._last_error != message:
            logger.warning(f"Bandwidth shaper: {message}")
        self._last_error = message


shaper = Shaper()
