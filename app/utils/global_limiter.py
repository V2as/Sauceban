"""The panel-wide cap: one token bucket per client address, kept by the kernel.

The blacklist caps a handful of named users, so :mod:`app.utils.shaper` can
afford a `tc` class and a filter per address it learned from the core. A cap
that applies to *everyone* cannot work that way: it would mean a class per
online address, rewritten whenever anybody connects or leaves, plus a list of
online addresses polled from the core for the sole purpose of building it.

So the kernel is asked to keep that state instead. One nftables rule per
direction and address family updates a dynamic set keyed by the client address
with a rate limit attached to each element: the first packet of an address
creates its token bucket, over-rate packets are dropped, and an address that
goes quiet is forgotten after GLOBAL_LIMIT_IP_TIMEOUT seconds. The cost is a
hash lookup per packet and about a hundred bytes per active address, whether
ten or ten thousand clients are online, and the panel process never has to
learn who is online at all — nothing is polled and nothing is rewritten while
the setting does not change.

What follows from that:

- **The unit is an address, not an account.** A user with a phone and a laptop
  gets the cap on each; clients behind one NAT address share one cap.
- **Only what a client opened is metered.** Connection tracking tells a client
  apart from a site the panel fetched on its behalf — both are on the far side
  of the same interface, and bucketing the latter by its own address would
  make one popular host a bucket shared by every client using it.
- **Both directions are policed** (over-rate packets dropped) rather than
  queued, like the upload side of the blacklist already is. Queueing a
  download needs a queue per address, which is the very thing being avoided.
- **A blacklist entry adds to this cap, it does not replace it.** The two
  mechanisms are independent, so a user hits whichever of the two is stricter.
"""
import json
import shutil
import subprocess
from threading import Lock
from time import time
from typing import Dict, Optional, Tuple

from app import logger
from app.utils.shaper import detect_interface
from config import (BLACKLIST_INTERFACE, GLOBAL_LIMIT_IP_TIMEOUT,
                    GLOBAL_LIMIT_MAX_IPS, GLOBAL_LIMIT_NFT_TIMEOUT)

# our own table, so nothing here can touch a firewall the operator built; the
# table is created and deleted as a whole and holds no filtering rules
_TABLE = "sauceban_bandwidth"
_DOWN_COUNTER = "down_drops"
_UP_COUNTER = "up_drops"
# how long a host that cannot limit is left alone before trying again
_RETRY_UNSUPPORTED = 300
# how often the rules are checked for still being there (`nft flush ruleset`
# from an unrelated firewall script would take them with it)
_VERIFY_INTERVAL = 60

_PERMISSION_HINT = (
    "the container needs NET_ADMIN (add `cap_add: [NET_ADMIN]` to the marzban "
    "service in docker-compose.yml and recreate it)"
)


def _ruleset(interface: str, mbps: int) -> str:
    """The whole table, as one atomic `nft -f` transaction.

    The empty declaration in front of the delete makes the transaction work
    whether or not the table is already there, which is what keeps reinstalling
    idempotent.
    """
    # nft takes the byte rate as a 32-bit number, so ~34 Gbit/s is as high as a
    # cap can be expressed; anything above that is no cap in practice anyway
    rate = min(mbps, 34_000) * 125_000  # megabits per second -> bytes per second
    # no `burst`: a byte-based bucket is already one second of traffic deep,
    # which absorbs both the jitter of a tunnel and the 64K packets
    # segmentation offload hands to the interface
    limit = f"limit rate over {rate} bytes/second"

    def rules(direction: str, counter: str) -> str:
        # `oifname`/`iifname` keeps the cap on the interface that carries the
        # tunnels: loopback and the docker bridges stay untouched.
        #
        # `ct direction` is what makes the far end of a packet the *client*.
        # Both a client and a site the panel fetches for it sit on the other
        # side of this interface; the client is the one that opened the
        # connection, so its packets are the original direction on the way in
        # and the reply direction on the way out. Without that test the rules
        # also bucket what comes back from a site, keyed by the site's address
        # — and everyone downloading from the same host ends up sharing one
        # bucket instead of getting one each.
        device, field, ct = (
            ("oifname", "daddr", "reply") if direction == "down"
            else ("iifname", "saddr", "original")
        )
        return "\n".join(
            f'\t\t{device} "{interface}" ct direction {ct} '
            f"update @{direction}{version} {{ {family} {field} {limit} }} "
            f'counter name "{counter}" drop'
            for version, family in (("4", "ip"), ("6", "ip6"))
        )

    sets = "\n".join(
        f"\tset {name} {{\n"
        f"\t\ttype {kind}\n"
        f"\t\tsize {GLOBAL_LIMIT_MAX_IPS}\n"
        f"\t\tflags dynamic,timeout\n"
        f"\t\ttimeout {GLOBAL_LIMIT_IP_TIMEOUT}s\n"
        f"\t}}"
        for name, kind in (("down4", "ipv4_addr"), ("down6", "ipv6_addr"),
                           ("up4", "ipv4_addr"), ("up6", "ipv6_addr"))
    )

    return (
        f"table inet {_TABLE} {{}}\n"
        f"delete table inet {_TABLE}\n"
        f"table inet {_TABLE} {{\n"
        f"\tcounter {_DOWN_COUNTER} {{}}\n"
        f"\tcounter {_UP_COUNTER} {{}}\n"
        f"{sets}\n"
        f"\tchain down {{\n"
        f"\t\ttype filter hook postrouting priority 0; policy accept;\n"
        f"{rules('down', _DOWN_COUNTER)}\n"
        f"\t}}\n"
        f"\tchain up {{\n"
        f"\t\ttype filter hook prerouting priority 0; policy accept;\n"
        f"{rules('up', _UP_COUNTER)}\n"
        f"\t}}\n"
        f"}}\n"
    )


def _teardown_script() -> str:
    return f"table inet {_TABLE} {{}}\ndelete table inet {_TABLE}\n"


class GlobalLimiter:
    """Keeps the kernel's per-address cap in sync with the setting."""

    def __init__(self) -> None:
        self._lock = Lock()
        # (interface, mbps) currently installed, or None
        self._applied: Optional[Tuple[str, int]] = None
        # whether a table left behind by a previous process has been dealt with
        self._cleaned = False
        self._last_applied_at: Optional[float] = None
        self._last_error: Optional[str] = None
        self._unsupported: Optional[str] = None
        self._unsupported_at: float = 0.0
        self._verified_at: float = 0.0

    # -- state -------------------------------------------------------------

    def status(self) -> dict:
        """What the API reports; costs nothing, reads no kernel state."""
        with self._lock:
            return {
                "available": self._unsupported is None,
                "unavailable_reason": self._unsupported,
                "interface": (
                    self._applied[0] if self._applied
                    else BLACKLIST_INTERFACE or None
                ),
                "last_applied_at": self._last_applied_at,
                "last_error": self._last_error,
            }

    def drops(self) -> Tuple[int, int]:
        """Packets the cap dropped since it was installed, (down, up)."""
        counters = self._counters()
        if not counters:
            return 0, 0
        return counters.get(_DOWN_COUNTER, 0), counters.get(_UP_COUNTER, 0)

    # -- reconciliation ----------------------------------------------------

    def apply(self, enabled: bool, mbps: int) -> None:
        """Make the kernel match the setting; no-op when nothing changed."""
        with self._lock:
            if not enabled:
                self._teardown()
                return

            if self._unsupported and time() - self._unsupported_at < _RETRY_UNSUPPORTED:
                # a box that cannot limit stays that way until it is
                # reconfigured; retry occasionally instead of on every tick
                return

            if not shutil.which("nft"):
                self._unavailable(
                    "the `nft` utility is missing from the image (install nftables)"
                )
                return

            interface = BLACKLIST_INTERFACE or detect_interface()
            if not interface:
                self._unavailable("no default-route interface to limit")
                return

            wanted = (interface, mbps)
            if self._applied == wanted:
                if time() - self._verified_at < _VERIFY_INTERVAL:
                    return
                if self._counters() is not None:
                    self._verified_at = time()
                    return
                logger.warning(
                    "Global bandwidth limit: the rules are gone from the kernel "
                    "(a firewall flush?), installing them again"
                )

            if self._run(_ruleset(interface, mbps)):
                self._applied = wanted
                self._cleaned = True
                self._last_applied_at = self._verified_at = time()

    def teardown(self) -> None:
        """Remove everything this module installed."""
        with self._lock:
            self._teardown()

    def _teardown(self) -> None:
        # the first pass also removes a table a previous process may have left
        # behind, which is why `_cleaned` is checked and not only `_applied`
        if self._applied is None and self._cleaned:
            return
        if shutil.which("nft"):
            self._run(_teardown_script(), quiet=True)
        self._cleaned = True
        if self._applied is not None:
            self._last_applied_at = time()
        self._applied = None
        self._verified_at = 0.0

    # -- nft plumbing ------------------------------------------------------

    def _counters(self) -> Optional[Dict[str, int]]:
        """Drop counters of the installed table, or None when it is not there.

        Deliberately asks for the counters only: listing the table would print
        every tracked address with it.
        """
        if self._applied is None:
            return None
        try:
            result = subprocess.run(
                ["nft", "-j", "list", "counters", "table", "inet", _TABLE],
                capture_output=True, text=True, timeout=GLOBAL_LIMIT_NFT_TIMEOUT,
            )
            if result.returncode != 0:
                return None
            objects = json.loads(result.stdout or "{}").get("nftables", [])
        except Exception as err:
            logger.debug(f"global limit: counters unavailable: {err}")
            return None

        counters: Dict[str, int] = {}
        for entry in objects:
            counter = entry.get("counter") if isinstance(entry, dict) else None
            if counter and counter.get("name"):
                counters[counter["name"]] = int(counter.get("packets", 0) or 0)
        return counters

    def _run(self, script: str, quiet: bool = False) -> bool:
        try:
            result = subprocess.run(
                ["nft", "-f", "-"], input=script,
                capture_output=True, text=True, timeout=GLOBAL_LIMIT_NFT_TIMEOUT,
            )
        except Exception as err:
            self._fail(f"running nft failed: {err}")
            return False

        if result.returncode != 0:
            if quiet:
                return False
            error = (result.stderr or result.stdout or "").strip()[:300]
            lowered = error.lower()
            if "not permitted" in lowered or "permission denied" in lowered:
                self._last_error = error
                self._unavailable(
                    f"nft is not allowed to change the ruleset: {_PERMISSION_HINT}"
                )
            elif "not supported" in lowered or "no such file" in lowered:
                self._unavailable(
                    "the kernel does not support the rules this cap needs "
                    f"(nftables dynamic sets): {error}"
                )
            else:
                self._fail(f"nft rejected the rules: {error}")
            return False

        self._unsupported = None
        self._last_error = None
        return True

    def _unavailable(self, reason: str) -> None:
        # an `nft -f` transaction is atomic: a rejected one changed nothing, so
        # whatever was installed before is still installed and `_applied` still
        # describes the kernel correctly
        if self._unsupported != reason:
            logger.warning(f"Global bandwidth limit unavailable: {reason}")
        self._unsupported = reason
        self._unsupported_at = time()

    def _fail(self, message: str) -> None:
        if self._last_error != message:
            logger.warning(f"Global bandwidth limit: {message}")
        self._last_error = message


global_limiter = GlobalLimiter()
