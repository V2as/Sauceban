import os

from decouple import config
from dotenv import load_dotenv

load_dotenv()


SQLALCHEMY_DATABASE_URL = config("SQLALCHEMY_DATABASE_URL", default="sqlite:///db.sqlite3")
SQLALCHEMY_POOL_SIZE = config("SQLALCHEMY_POOL_SIZE", cast=int, default=10)
SQLIALCHEMY_MAX_OVERFLOW = config("SQLIALCHEMY_MAX_OVERFLOW", cast=int, default=30)

UVICORN_HOST = config("UVICORN_HOST", default="0.0.0.0")
UVICORN_PORT = config("UVICORN_PORT", cast=int, default=8000)
UVICORN_UDS = config("UVICORN_UDS", default=None)
UVICORN_SSL_CERTFILE = config("UVICORN_SSL_CERTFILE", default=None)
UVICORN_SSL_KEYFILE = config("UVICORN_SSL_KEYFILE", default=None)
UVICORN_SSL_CA_TYPE = config("UVICORN_SSL_CA_TYPE", default="public").lower()
DASHBOARD_PATH = config("DASHBOARD_PATH", default="/dashboard/")

DEBUG = config("DEBUG", default=False, cast=bool)
DOCS = config("DOCS", default=False, cast=bool)

ALLOWED_ORIGINS = config("ALLOWED_ORIGINS", default="*").split(",")

VITE_BASE_API = f"http://127.0.0.1:{UVICORN_PORT}/api/" \
    if DEBUG and config("VITE_BASE_API", default="/api/") == "/api/" \
    else config("VITE_BASE_API", default="/api/")

XRAY_JSON = config("XRAY_JSON", default="./xray_config.json")
XRAY_FALLBACKS_INBOUND_TAG = config("XRAY_FALLBACKS_INBOUND_TAG", cast=str, default="") or config(
    "XRAY_FALLBACK_INBOUND_TAG", cast=str, default=""
)
XRAY_EXECUTABLE_PATH = config("XRAY_EXECUTABLE_PATH", default="/usr/local/bin/xray")
XRAY_ASSETS_PATH = config("XRAY_ASSETS_PATH", default="/usr/local/share/xray")
# Soft memory limit (GOMEMLIMIT) handed to the Xray process, kept in a file
# next to the core config instead of the environment: `marzban gomemlimit`
# changes it without recreating the panel container, and the core health check
# restarts the core when the file stops matching the running process.
XRAY_GO_ENV_FILE = config(
    "XRAY_GO_ENV_FILE",
    default=os.path.join(os.path.dirname(os.path.abspath(XRAY_JSON)), "xray_go_env"),
)
XRAY_EXCLUDE_INBOUND_TAGS = config("XRAY_EXCLUDE_INBOUND_TAGS", default='').split()
XRAY_SUBSCRIPTION_URL_PREFIX = config("XRAY_SUBSCRIPTION_URL_PREFIX", default="").strip("/")
XRAY_SUBSCRIPTION_PATH = config("XRAY_SUBSCRIPTION_PATH", default="sub").strip("/")

TELEGRAM_API_TOKEN = config("TELEGRAM_API_TOKEN", default="")
TELEGRAM_ADMIN_ID = config(
    'TELEGRAM_ADMIN_ID',
    default="",
    cast=lambda v: [int(i) for i in filter(str.isdigit, (s.strip() for s in v.split(',')))]
)
TELEGRAM_PROXY_URL = config("TELEGRAM_PROXY_URL", default="")
TELEGRAM_LOGGER_CHANNEL_ID = config("TELEGRAM_LOGGER_CHANNEL_ID", cast=int, default=0)
TELEGRAM_DEFAULT_VLESS_FLOW = config("TELEGRAM_DEFAULT_VLESS_FLOW", default="")

JWT_ACCESS_TOKEN_EXPIRE_MINUTES = config("JWT_ACCESS_TOKEN_EXPIRE_MINUTES", cast=int, default=1440)

CUSTOM_TEMPLATES_DIRECTORY = config("CUSTOM_TEMPLATES_DIRECTORY", default=None)
SUBSCRIPTION_PAGE_TEMPLATE = config("SUBSCRIPTION_PAGE_TEMPLATE", default="subscription/index.html")
HOME_PAGE_TEMPLATE = config("HOME_PAGE_TEMPLATE", default="home/index.html")

CLASH_SUBSCRIPTION_TEMPLATE = config("CLASH_SUBSCRIPTION_TEMPLATE", default="clash/default.yml")
CLASH_SETTINGS_TEMPLATE = config("CLASH_SETTINGS_TEMPLATE", default="clash/settings.yml")

SINGBOX_SUBSCRIPTION_TEMPLATE = config("SINGBOX_SUBSCRIPTION_TEMPLATE", default="singbox/default.json")
SINGBOX_SETTINGS_TEMPLATE = config("SINGBOX_SETTINGS_TEMPLATE", default="singbox/settings.json")

MUX_TEMPLATE = config("MUX_TEMPLATE", default="mux/default.json")

V2RAY_SUBSCRIPTION_TEMPLATE = config("V2RAY_SUBSCRIPTION_TEMPLATE", default="v2ray/default.json")
V2RAY_SETTINGS_TEMPLATE = config("V2RAY_SETTINGS_TEMPLATE", default="v2ray/settings.json")

USER_AGENT_TEMPLATE = config("USER_AGENT_TEMPLATE", default="user_agent/default.json")
GRPC_USER_AGENT_TEMPLATE = config("GRPC_USER_AGENT_TEMPLATE", default="user_agent/grpc.json")

EXTERNAL_CONFIG = config("EXTERNAL_CONFIG", default="", cast=str)
LOGIN_NOTIFY_WHITE_LIST = [ip.strip() for ip in config("LOGIN_NOTIFY_WHITE_LIST",
                                                       default="", cast=str).split(",") if ip.strip()]

USE_CUSTOM_JSON_DEFAULT = config("USE_CUSTOM_JSON_DEFAULT", default=False, cast=bool)
USE_CUSTOM_JSON_FOR_V2RAYN = config("USE_CUSTOM_JSON_FOR_V2RAYN", default=False, cast=bool)
USE_CUSTOM_JSON_FOR_V2RAYNG = config("USE_CUSTOM_JSON_FOR_V2RAYNG", default=False, cast=bool)
USE_CUSTOM_JSON_FOR_STREISAND = config("USE_CUSTOM_JSON_FOR_STREISAND", default=False, cast=bool)
USE_CUSTOM_JSON_FOR_HAPP = config("USE_CUSTOM_JSON_FOR_HAPP", default=False, cast=bool)

NOTIFY_STATUS_CHANGE = config("NOTIFY_STATUS_CHANGE", default=True, cast=bool)
NOTIFY_USER_CREATED = config("NOTIFY_USER_CREATED", default=True, cast=bool)
NOTIFY_USER_UPDATED = config("NOTIFY_USER_UPDATED", default=True, cast=bool)
NOTIFY_USER_DELETED = config("NOTIFY_USER_DELETED", default=True, cast=bool)
NOTIFY_USER_DATA_USED_RESET = config("NOTIFY_USER_DATA_USED_RESET", default=True, cast=bool)
NOTIFY_USER_SUB_REVOKED = config("NOTIFY_USER_SUB_REVOKED", default=True, cast=bool)
NOTIFY_IF_DATA_USAGE_PERCENT_REACHED = config("NOTIFY_IF_DATA_USAGE_PERCENT_REACHED", default=True, cast=bool)
NOTIFY_IF_DAYS_LEFT_REACHED = config("NOTIFY_IF_DAYS_LEFT_REACHED", default=True, cast=bool)
NOTIFY_LOGIN = config("NOTIFY_LOGIN", default=True, cast=bool)

ACTIVE_STATUS_TEXT = config("ACTIVE_STATUS_TEXT", default="Active")
EXPIRED_STATUS_TEXT = config("EXPIRED_STATUS_TEXT", default="Expired")
LIMITED_STATUS_TEXT = config("LIMITED_STATUS_TEXT", default="Limited")
DISABLED_STATUS_TEXT = config("DISABLED_STATUS_TEXT", default="Disabled")
ONHOLD_STATUS_TEXT = config("ONHOLD_STATUS_TEXT", default="On-Hold")

USERS_AUTODELETE_DAYS = config("USERS_AUTODELETE_DAYS", default=-1, cast=int)
USER_AUTODELETE_INCLUDE_LIMITED_ACCOUNTS = config("USER_AUTODELETE_INCLUDE_LIMITED_ACCOUNTS", default=False, cast=bool)


# USERNAME: PASSWORD
SUDOERS = {config("SUDO_USERNAME"): config("SUDO_PASSWORD")} \
    if config("SUDO_USERNAME", default='') and config("SUDO_PASSWORD", default='') \
    else {}


WEBHOOK_ADDRESS = config(
    'WEBHOOK_ADDRESS',
    default="",
    cast=lambda v: [address.strip() for address in v.split(',')] if v else []
)
WEBHOOK_SECRET = config("WEBHOOK_SECRET", default=None)

# recurrent notifications

# timeout between each retry of sending a notification in seconds
RECURRENT_NOTIFICATIONS_TIMEOUT = config("RECURRENT_NOTIFICATIONS_TIMEOUT", default=180, cast=int)
# how many times to try after ok response not recevied after sending a notifications
NUMBER_OF_RECURRENT_NOTIFICATIONS = config("NUMBER_OF_RECURRENT_NOTIFICATIONS", default=3, cast=int)

# sends a notification when the user uses this much of thier data
NOTIFY_REACHED_USAGE_PERCENT = config(
    "NOTIFY_REACHED_USAGE_PERCENT",
    default="80",
    cast=lambda v: [int(p.strip()) for p in v.split(',')] if v else []
)

# sends a notification when there is n days left of their service
NOTIFY_DAYS_LEFT = config(
    "NOTIFY_DAYS_LEFT",
    default="3",
    cast=lambda v: [int(d.strip()) for d in v.split(',')] if v else []
)

DISABLE_RECORDING_NODE_USAGE = config("DISABLE_RECORDING_NODE_USAGE", cast=bool, default=False)

# headers: profile-update-interval, support-url, profile-title
SUB_UPDATE_INTERVAL = config("SUB_UPDATE_INTERVAL", default="12")
SUB_SUPPORT_URL = config("SUB_SUPPORT_URL", default="https://t.me/")
SUB_PROFILE_TITLE = config("SUB_PROFILE_TITLE", default="Subscription")

# discord webhook log
DISCORD_WEBHOOK_URL = config("DISCORD_WEBHOOK_URL", default="")


# Interval jobs, all values are in seconds
JOB_CORE_HEALTH_CHECK_INTERVAL = config("JOB_CORE_HEALTH_CHECK_INTERVAL", cast=int, default=10)
JOB_RECORD_NODE_USAGES_INTERVAL = config("JOB_RECORD_NODE_USAGES_INTERVAL", cast=int, default=30)
JOB_RECORD_USER_USAGES_INTERVAL = config("JOB_RECORD_USER_USAGES_INTERVAL", cast=int, default=10)
JOB_REVIEW_USERS_INTERVAL = config("JOB_REVIEW_USERS_INTERVAL", cast=int, default=10)
JOB_SEND_NOTIFICATIONS_INTERVAL = config("JOB_SEND_NOTIFICATIONS_INTERVAL", cast=int, default=30)

# Push-metrics schedulers (webhook statistics)
# Minimum allowed interval (in seconds) for a push scheduler, protects the
# system from being overloaded with too frequent metric collection.
PUSH_SCHEDULER_MIN_INTERVAL = config("PUSH_SCHEDULER_MIN_INTERVAL", cast=int, default=5)
# How often (in seconds) the manager reconciles APScheduler jobs with the
# scheduler rows stored in the database (add/update/remove).
JOB_SYNC_PUSH_SCHEDULERS_INTERVAL = config("JOB_SYNC_PUSH_SCHEDULERS_INTERVAL", cast=int, default=15)
# For how long (in seconds) a collected metrics snapshot is reused across
# schedulers that fire at (nearly) the same time. Keeps collection cheap.
PUSH_METRICS_CACHE_TTL = config("PUSH_METRICS_CACHE_TTL", cast=int, default=2)
# HTTP timeout (seconds) when delivering a push to a webhook.
PUSH_WEBHOOK_TIMEOUT = config("PUSH_WEBHOOK_TIMEOUT", cast=int, default=15)


# Traffic-anomaly monitor (detects shared subscriptions)
# Lower bound for the sampling interval and for the per-webhook push spacing.
ANOMALY_MIN_SAMPLE_INTERVAL = config("ANOMALY_MIN_SAMPLE_INTERVAL", cast=int, default=5)
# How often (in seconds) the sampler job is reconciled with the settings row
# stored in the database (enable/disable, interval changes).
JOB_SYNC_ANOMALY_MONITOR_INTERVAL = config("JOB_SYNC_ANOMALY_MONITOR_INTERVAL", cast=int, default=15)
# gRPC timeout (seconds) for one online-IP snapshot per core/node.
ANOMALY_STATS_TIMEOUT = config("ANOMALY_STATS_TIMEOUT", cast=int, default=10)
# Ceiling on how many users the sliding window keeps in memory; the least
# recently seen ones are dropped first.
ANOMALY_MAX_TRACKED_USERS = config("ANOMALY_MAX_TRACKED_USERS", cast=int, default=5000)
# Cores without the bulk GetUsersStats RPC are probed one user at a time.
# Caps how many of the heaviest recently-online users get probed per sample.
ANOMALY_PROBE_LIMIT = config("ANOMALY_PROBE_LIMIT", cast=int, default=100)


# Per-user bandwidth caps (the "blacklist")
# How often (in seconds) the caps stored in the database and the source IPs of
# the capped users are reconciled with the kernel's traffic control state.
JOB_SYNC_BLACKLIST_INTERVAL = config("JOB_SYNC_BLACKLIST_INTERVAL", cast=int, default=10)
# Enforce the caps with `tc`. Turn off to keep the blacklist as bookkeeping
# only (no qdisc is installed, the API and dashboard keep working).
BLACKLIST_ENFORCE = config("BLACKLIST_ENFORCE", cast=bool, default=True)
# Interface the tunnel traffic leaves through; empty means the interface of
# the default route.
BLACKLIST_INTERFACE = config("BLACKLIST_INTERFACE", default="")
# Rate of the catch-all class every uncapped packet falls into; must be at or
# above the real link speed or it would throttle the whole server.
BLACKLIST_LINK_MBPS = config("BLACKLIST_LINK_MBPS", cast=int, default=10000)
# How long (in seconds) an address keeps being shaped after the user was last
# seen using it. Absorbs gaps between samples instead of flapping the rules.
BLACKLIST_IP_TTL = config("BLACKLIST_IP_TTL", cast=int, default=180)
# Highest cap the API accepts, in megabits per second.
BLACKLIST_MAX_MBPS = config("BLACKLIST_MAX_MBPS", cast=int, default=10000)
# gRPC timeout (seconds) for reading the online IPs of the capped users.
BLACKLIST_STATS_TIMEOUT = config("BLACKLIST_STATS_TIMEOUT", cast=int, default=10)
# Timeout (seconds) for one `tc` invocation.
BLACKLIST_TC_TIMEOUT = config("BLACKLIST_TC_TIMEOUT", cast=int, default=10)


# Panel-wide cap given to every address separately (the "global limit").
# Whether it is on and how fast it is lives in the database, managed through
# the API and the dashboard; these variables only tune the plumbing.
# How long (in seconds) the kernel keeps the token bucket of an address after
# its last packet. Only affects when memory is reclaimed, not the cap itself.
GLOBAL_LIMIT_IP_TIMEOUT = config("GLOBAL_LIMIT_IP_TIMEOUT", cast=int, default=120)
# Ceiling on addresses tracked per direction and address family. A full table
# means new addresses run uncapped, never blocked.
GLOBAL_LIMIT_MAX_IPS = config("GLOBAL_LIMIT_MAX_IPS", cast=int, default=65536)
# Timeout (seconds) for one `nft` invocation.
GLOBAL_LIMIT_NFT_TIMEOUT = config("GLOBAL_LIMIT_NFT_TIMEOUT", cast=int, default=10)
