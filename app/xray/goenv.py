import re
from typing import Optional

from app import logger
from config import XRAY_GO_ENV_FILE

# The Go runtime takes a byte count with an optional IEC suffix; "1G", "1GB"
# and other decimal spellings make it abort at startup, so anything it would
# not accept is dropped here instead of killing the core.
_LIMIT_PATTERN = re.compile(r"^[1-9][0-9]*(?:B|KiB|MiB|GiB|TiB)?$")
_MAX_FILE_BYTES = 4096

_last_warning = None


def _warn_once(message: str) -> None:
    # the core health check reads the file on every tick, so a file that stays
    # broken would otherwise fill the log with the same line
    global _last_warning
    if message != _last_warning:
        _last_warning = message
        logger.warning(message)


def read_memory_limit() -> Optional[str]:
    """GOMEMLIMIT for the next core start; None means the core runs uncapped."""
    try:
        with open(XRAY_GO_ENV_FILE, "r", encoding="utf-8") as file:
            raw = file.read(_MAX_FILE_BYTES)
    except FileNotFoundError:
        return None
    except OSError as exc:
        _warn_once(f"Cannot read {XRAY_GO_ENV_FILE} ({exc}), Xray runs without a memory limit")
        return None

    value = None
    for line in raw.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        key, separator, candidate = line.partition("=")
        if separator and key.strip() == "GOMEMLIMIT":
            value = candidate.strip()

    if not value or value == "off":
        return None

    if not _LIMIT_PATTERN.match(value):
        _warn_once(f"Ignoring GOMEMLIMIT={value} in {XRAY_GO_ENV_FILE}: not a size the Go runtime accepts")
        return None

    return value
