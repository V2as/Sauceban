# Traffic Anomaly Monitor (USAGE-ANOMALY)

This document describes the **traffic anomaly monitor**: a lightweight detector
for subscriptions that are being used from several places at once (a key handed
out to friends), plus configurable webhook targets that receive the findings.

It answers one question: *is a single subscription being used by more people
than it was sold for, and is that actually loading the server?*

Nobody is blocked, throttled or disabled — the feature only reports. What the
receiving side does with a report is its own decision.

It is fully additive. With monitoring disabled (the default) nothing runs, no
extra queries are made, and the existing push-metrics feature
([`USAGE-PUSH.md`](USAGE-PUSH.md)) is untouched.

---

## Contents

- [How detection works](#how-detection-works)
- [Requirements](#requirements)
- [Turning the monitor on and off](#turning-the-monitor-on-and-off)
- [Tuning the detector](#tuning-the-detector)
- [Managing webhook targets via the API](#managing-webhook-targets-via-the-api)
- [Managing everything via marzban-cli](#managing-everything-via-marzban-cli)
- [Managing everything via the dashboard](#managing-everything-via-the-dashboard)
- [The anomaly payload](#the-anomaly-payload)
- [Verifying the request (secret key + HMAC)](#verifying-the-request-secret-key--hmac)
- [Delivery behaviour](#delivery-behaviour)
- [Configuration](#configuration)

---

## How detection works

Every `sample_interval` seconds the monitor asks each running Xray core (local
core + every connected node) for the source IPs that currently hold
connections, one gRPC call per core. For the users that show up it reads their
traffic counters with a single indexed `SELECT`. There is no log parsing and no
per-user fan-out, so the cost of a tick does not grow with the number of
subscriptions you sell.

Everything else happens in memory over a sliding `window_seconds` window.
Precision comes from four guards rather than from one big threshold:

**Subnet collapsing.** Mobile carriers rotate the egress address of a *single*
device mid-session, and dual-stack clients show an IPv4 and an IPv6 address at
the same time. Raw IP counts alarm on those honest users. The monitor therefore
groups addresses into /24 (IPv4) and /64 (IPv6) networks, which collapses the
rotation while sharing between households still crosses network boundaries. The
raw IP rules additionally require the addresses to span at least two networks
before they can fire at all.

**Simultaneity.** A device that moves visits networks one after another; a
shared key has several networks connected *at the same instant*. The
highest-weighted rule counts networks within a single sample
(`max_concurrent_networks`), not across the window — that is what separates a
commuter from a reseller.

**Sustained hits.** A rule must fire on `min_hits` consecutive samples before
anything is reported. One-off samples (a reconnect from a new IP, Happy
Eyeballs, a brief dual-stack overlap) never produce a report.

**A load gate.** `min_traffic_rate_mbps` requires the user to actually push
traffic before a report goes out. This is the difference between "shared" and
"shared and costing you capacity". It is `0` (off) by default; set it to
something like `5` on a busy server so you only hear about sharing that hurts.

Each triggered rule adds to a score; the score maps to a fixed severity scale
(`low` < 35 ≤ `medium` < 55 ≤ `high` < 75 ≤ `critical`). Thresholds are what an
operator tunes — the severity scale stays comparable between panels so a
central receiver can filter on it.

After a user is reported it is suppressed for `cooldown_seconds`. A suppressed
user still appears in the live report (flagged `suppressed: true`) and is
re-reported early only if its score climbs clearly higher than the score it was
reported with.

Memory is bounded: at most `ANOMALY_MAX_TRACKED_USERS` window states, each
holding only the IPs, per-sample counts and traffic samples of the last window.
Nothing is written to the database, so a panel restart simply starts with an
empty window.

---

## Requirements

The monitor reads per-user online IPs from the Xray core. Sauceban always sets
`policy.levels."0".statsUserOnline = true` in the generated config, so nothing
needs to be added to `XRAY_JSON`.

The three RPCs it can use landed in three different Xray releases, so the
monitor walks down the list until one answers:

| Xray-core | RPC | What the monitor does |
|---|---|---|
| ≥ `v26.4.13` | `GetUsersStats` | one call per core per tick — `ip_source: "bulk"` |
| ≥ `v25.12.1` | `GetAllOnlineUsers` + `GetStatsOnlineIpList` | asks who is online, then one probe each (up to `ANOMALY_PROBE_LIMIT`) — `ip_source: "probe"` |
| ≥ `v25.2.18` | `GetStatsOnlineIpList` | probes the users that moved the most traffic recently — `ip_source: "probe"` |
| older | — | `ip_source: "unavailable"` plus a warning; sharing cannot be detected |

**`ip_source: "unavailable"` means "update Xray".** Nothing else in the panel
needs to change; the version of the panel or of Marzban-Node does not matter,
only the core binary on the machine that terminates the traffic. Check it with
`xray version` (or `docker exec marzban xray version`), and note that each node
runs its own core — a node that is too old just contributes no observations.

Older cores that do not know `statsUserOnline` ignore the key, so enabling the
monitor on them is harmless — it just never sees any IPs.

If Xray sits behind a reverse proxy (nginx stream, HAProxy, CDN) every source
IP it sees is the proxy's. The monitor detects this case and puts a warning in
`monitor.warnings` instead of reporting everyone; enable the PROXY protocol on
the inbound to get real client addresses.

---

## Turning the monitor on and off

The master switch is a single setting. All three interfaces write the same row
and take effect within `JOB_SYNC_ANOMALY_MONITOR_INTERVAL` seconds (immediately
when changed through the API or the dashboard).

```bash
# API
curl -X PUT https://your-panel/api/anomaly/settings \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"is_enabled": true}'

# CLI
marzban cli anomaly enable
marzban cli anomaly disable
```

In the dashboard: **menu (☰) → "Anomaly Monitor" → the switch at the top**.

Turning the monitor off removes the sampling job and drops all window state, so
turning it back on starts from a clean window.

---

## Tuning the detector

`GET`/`PUT` `/api/anomaly/settings` (sudo admin). `PUT` is partial — send only
the fields you want to change.

| Field | Default | Meaning |
|---|---|---|
| `is_enabled` | `false` | Master switch. |
| `sample_interval` | `30` | Seconds between snapshots (min `ANOMALY_MIN_SAMPLE_INTERVAL`). |
| `window_seconds` | `300` | Sliding window the rules look at. |
| `max_concurrent_networks` | `2` | Networks allowed online at the same instant (`0` = rule off). |
| `max_subnets` | `3` | Networks allowed anywhere in the window (`0` = rule off). |
| `max_ips` | `6` | Source IPs allowed in the window (`0` = rule off). |
| `min_hits` | `2` | Consecutive samples a rule must hold before reporting. |
| `min_traffic_rate_mbps` | `0` | Load gate: only report above this rate (`0` = off). |
| `traffic_spike_ratio` | `0` | Also report at this multiple of the user's own baseline (`0` = off). |
| `cooldown_seconds` | `900` | Per-user re-report suppression. |
| `include_ips` | `true` | Send raw source IPs as evidence. |
| `max_ips_in_report` | `20` | Cap on IPs per reported user. |

The defaults are deliberately conservative: they catch a key used from several
households simultaneously and stay quiet about one person with a phone, a
laptop and a flaky carrier. Raise `max_concurrent_networks` if you sell
multi-device plans; set `min_traffic_rate_mbps` if you only care about sharing
that costs you bandwidth.

To see what the monitor currently thinks without pushing anything:

```bash
curl "https://your-panel/api/anomaly/report?include_suppressed=true" \
  -H "Authorization: Bearer $TOKEN"

# and for one user's live window state:
curl https://your-panel/api/anomaly/users/john/activity \
  -H "Authorization: Bearer $TOKEN"
```

`GET /report` is read-only: it does not advance sustained-hit counters or
cooldowns, so polling it cannot change what the webhooks receive.

---

## Managing webhook targets via the API

A **target** is an independent webhook with its own severity floor and spacing.
All endpoints require a **sudo admin** bearer token. Base prefix:
`/api/anomaly`.

| Method | Path | Description |
|---|---|---|
| `GET` | `/api/anomaly/settings` | Read monitor settings. |
| `PUT` | `/api/anomaly/settings` | Update monitor settings (partial). |
| `GET` | `/api/anomaly/schedulers` | List targets with runtime status. |
| `POST` | `/api/anomaly/schedulers` | Create a target. |
| `GET` | `/api/anomaly/schedulers/{id}` | Get one target. |
| `PUT` | `/api/anomaly/schedulers/{id}` | Modify a target (partial). |
| `DELETE` | `/api/anomaly/schedulers/{id}` | Delete a target. |
| `POST` | `/api/anomaly/schedulers/{id}/trigger` | Push the current report now (test run). |
| `GET` | `/api/anomaly/report` | Preview the exact payload without pushing. |
| `GET` | `/api/anomaly/users/{username}/activity` | Live window state of one user. |

Target fields:

| Field | Description |
|---|---|
| `name` | Human readable label. |
| `webhook_url` | The HTTP(S) endpoint that receives the push (`POST`). |
| `secret_key` | Optional secret used to authenticate/sign the request. |
| `interval` | Minimum seconds between pushes to this target (min `ANOMALY_MIN_SAMPLE_INTERVAL`). |
| `is_enabled` | Enable/disable sending without deleting the target. |
| `min_severity` | Only send findings at or above this severity (`low`/`medium`/`high`/`critical`). |
| `send_empty` | Push a heartbeat even when nothing was found. |

### Create

```bash
curl -X POST https://your-panel/api/anomaly/schedulers \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Abuse watcher",
    "webhook_url": "https://monitoring.example.com/marzban/anomalies",
    "secret_key": "super-secret-token",
    "interval": 60,
    "is_enabled": true,
    "min_severity": "medium",
    "send_empty": false
  }'
```

### List (with statuses)

```bash
curl https://your-panel/api/anomaly/schedulers -H "Authorization: Bearer $TOKEN"
```

Each item includes `last_run_at`, `last_status` (`success`/`failed`/`pending`),
`last_status_code`, `last_error`, `total_runs`, `failed_runs` and
`total_anomalies_sent`.

### Update / delete / test

```bash
curl -X PUT https://your-panel/api/anomaly/schedulers/1 \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"min_severity": "high", "interval": 300}'

curl -X DELETE https://your-panel/api/anomaly/schedulers/1 \
  -H "Authorization: Bearer $TOKEN"

curl -X POST https://your-panel/api/anomaly/schedulers/1/trigger \
  -H "Authorization: Bearer $TOKEN"
# -> {"success": true, "status_code": 200, "error": null, "anomalies_sent": 2}
```

To clear the secret key, pass `"secret_key": null`. A trigger ignores
`is_enabled`, `min_severity` and the spacing — it sends whatever the monitor
sees right now.

---

## Managing everything via marzban-cli

```bash
marzban cli anomaly settings                  # current settings + live status
marzban cli anomaly enable
marzban cli anomaly disable
marzban cli anomaly configure --max-concurrent-networks 3 --min-rate 5 \
    --window 600 --cooldown 1800
marzban cli anomaly report                    # what the monitor sees right now

marzban cli anomaly list
marzban cli anomaly show <id>
marzban cli anomaly create --name "Abuse watcher" \
    --webhook-url "https://.../anomalies" --interval 60 \
    --secret "super-secret-token" --min-severity medium --enabled
marzban cli anomaly update <id> --min-severity high --disabled
marzban cli anomaly send-now <id>
marzban cli anomaly delete <id> -y
```

(When running directly: `marzban-cli.py anomaly ...`)

Note that `report` and `send-now` run in a **separate process** from the panel,
which has its own empty window state. Use the API or the dashboard to see the
live picture; the CLI is for configuration and for scripting.

---

## Managing everything via the dashboard

Menu (☰) → **"Anomaly Monitor"** (sudo admins only):

- the master switch, with the current IP source, online/tracked counts and any
  warnings from the last sample;
- **Detection settings** — every threshold from the table above;
- **Live anomalies** — what is being detected right now, with the rules that
  fired, the score and the evidence, including users held back by a cooldown;
- one accordion per webhook target: name, URL, secret, spacing, severity floor,
  *Send even when there is nothing to report*, a status badge, **Send now** and
  delete.

---

## The anomaly payload

One `POST` with `Content-Type: application/json`. The `User-Agent` is
`Marzban-AnomalyMonitor/1.0`, which distinguishes anomaly pushes from
push-metrics pushes (`Marzban-PushMetrics/1.0`) on a shared receiver.

```jsonc
{
  "schema_version": "1.0",
  "event": "traffic_anomaly_report",
  "timestamp": 1788712119.68,        // unix seconds
  "collected_in_ms": 12.4,
  "instance": "my-server-hostname",
  "scheduler_id": 1,
  "scheduler_name": "Abuse watcher",

  "monitor": {
    "is_enabled": true,
    "ip_source": "bulk",             // bulk | probe | unavailable | unknown
    "sample_interval": 30,
    "window_seconds": 300,
    "thresholds": { "max_concurrent_networks": 2, "max_subnets": 3, "max_ips": 6,
                    "min_hits": 2, "min_traffic_rate_mbps": 5.0,
                    "traffic_spike_ratio": 3.0, "cooldown_seconds": 900 },
    "last_sample_at": 1788712119.67,
    "last_error": null,
    "nodes_sampled": ["master", "de-1"],
    "nodes_failed": [],
    "tracked_users": 2,
    "users_online": 2,
    "warnings": []
  },

  "summary": {
    "anomalies_total": 1,
    "suppressed_total": 0,
    "by_severity": { "critical": 1 },
    "max_score": 88
  },

  "anomalies": [
    {
      "username": "alice",
      "severity": "critical",        // low | medium | high | critical
      "score": 88,
      "detected_at": 1788712119.68,
      "suppressed": false,           // true = repeat held back by the cooldown

      // which rules fired, with the observed value and the configured limit
      "reasons": [
        { "rule": "concurrent_networks", "value": 4.0, "threshold": 2.0 },
        { "rule": "distinct_subnets",    "value": 4.0, "threshold": 3.0 },
        { "rule": "traffic_rate_mbps",   "value": 858.99, "threshold": 5.0 }
      ],

      "evidence": {
        "distinct_ips": 5,
        "distinct_subnets": 4,
        "peak_concurrent_ips": 5,
        "peak_concurrent_networks": 4,   // strongest sharing signal
        "ips": [                          // empty when include_ips = false
          { "ip": "91.108.4.10", "last_seen": 1788712059, "network": "91.108.4.0/24" },
          { "ip": "176.59.12.3", "last_seen": 1788712059, "network": "176.59.12.0/24" }
        ],
        "subnets": ["176.59.12.0/24", "2a02:6b8:c00::/64", "5.101.220.0/24", "91.108.4.0/24"],
        "nodes": ["master"],              // where the user was seen
        "window_traffic_bytes": 6442450944,
        "traffic_rate_bytes_per_sec": 107374182.4,
        "traffic_rate_mbps": 858.993,
        "baseline_rate_bytes_per_sec": 0.0,
        "traffic_ratio": 0.0,             // rate / baseline
        "samples": 3,                     // samples in the window
        "hits": 2,                        // consecutive samples the rules held
        "first_seen_at": 1788711999.66,
        "last_seen_at": 1788712059.66
      },

      // everything the receiver needs to act on the report
      "client": {
        "username": "alice",
        "email": "7.alice",               // the Xray-side identity
        "user_id": 7,
        "status": "active",
        "used_traffic": 45097156608,
        "lifetime_used_traffic": 45097156608,
        "data_limit": 214748364800,
        "data_limit_reset_strategy": "no_reset",
        "expire": 1790429272,
        "online_at": "2026-09-06T16:27:52",
        "created_at": "2026-09-06T16:27:52",
        "sub_updated_at": "2026-09-06T16:27:52",
        "sub_last_user_agent": "v2rayNG/1.8.19",
        "admin": "superadmin",
        "note": "sold as 3 devices"
      }
    }
  ]
}
```

`rule` values: `concurrent_networks`, `distinct_subnets`, `distinct_ips`,
`traffic_spike`, `traffic_rate_mbps`. The last one is context rather than a
trigger: it appears whenever the load gate is enabled, to show how much load
the sharing actually causes. The rate itself is always in `evidence`.

A heartbeat (`send_empty: true`) is the same object with
`"anomalies": []` and a zeroed `summary`.

---

## Verifying the request (secret key + HMAC)

Identical to push metrics. When a target has a `secret_key`:

| Header | Value |
|---|---|
| `X-Webhook-Secret` | The raw secret key (simple shared-secret check). |
| `X-Signature-256` | `sha256=<hex>` HMAC-SHA256 of the **raw request body** keyed by the secret. |

Always verify against the raw bytes of the body, before JSON parsing. See
[`USAGE-PUSH.md`](USAGE-PUSH.md#verifying-the-request-secret-key--hmac) for
ready-to-paste Python and Node.js receivers — the verification code is the
same, only the payload differs.

---

## Delivery behaviour

A receiver can rely on the following:

- **Findings are queued per target, not dropped.** If a target is throttled by
  its `interval`, or the webhook is down, findings accumulate (highest score
  per user wins) and go out with the next successful push. The queue is capped
  at 200 users per target; the lowest scores are dropped first.
- **The queue is cleared only on success.** A failed delivery keeps everything
  pending and is logged with the HTTP status / error, which is also stored on
  the target (`last_status`, `last_error`).
- **Suppressed findings are never pushed.** They exist for the UI and for
  `GET /report`; the cooldown is what keeps a receiver from being flooded by
  the same user.
- **`min_severity` is applied per target**, so one receiver can take everything
  while another only hears about `critical`.
- **Deleting a target drops its queue.** Targets are reconciled with the
  database on every tick, so changes take effect without a restart.

---

## Configuration

Runtime configuration lives in the database (`anomaly_settings` and
`anomaly_schedulers`, added by Alembic migration `b7c8d9e0f1a2`) and is managed
through the API / CLI / dashboard. These optional environment variables tune
the plumbing:

| Variable | Default | Description |
|---|---|---|
| `ANOMALY_MIN_SAMPLE_INTERVAL` | `5` | Lower bound for `sample_interval` and for a target's `interval`. |
| `JOB_SYNC_ANOMALY_MONITOR_INTERVAL` | `15` | How often the sampler job is reconciled with the settings row. |
| `ANOMALY_STATS_TIMEOUT` | `10` | gRPC timeout (seconds) per core when sampling online IPs. |
| `ANOMALY_MAX_TRACKED_USERS` | `5000` | Cap on per-user window states kept in memory. |
| `ANOMALY_PROBE_LIMIT` | `100` | Users probed individually when the core has no bulk RPC. |

The monitor runs in the panel process next to the other jobs, so the
single-uvicorn-worker rule applies to it as well.
