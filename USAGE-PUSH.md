# Push Statistics Webhooks (USAGE-PUSH)

This document describes the **push statistics** feature: configurable schedulers
that periodically POST server and Marzban metrics (plus the full users list) to
one or more webhook endpoints. The payload is a standardized JSON object that is
friendly to Prometheus / Grafana style monitoring pipelines.

It is fully additive — existing notification/webhook behaviour
(`WEBHOOK_ADDRESS` event notifications) is untouched, so you can safely
`marzban update` into it.

---

## Contents

- [Concepts](#concepts)
- [Managing schedulers via the API](#managing-schedulers-via-the-api)
- [Managing schedulers via marzban-cli](#managing-schedulers-via-marzban-cli)
- [Managing schedulers via the dashboard](#managing-schedulers-via-the-dashboard)
- [The push payload](#the-push-payload)
- [Verifying the request (secret key + HMAC)](#verifying-the-request-secret-key--hmac)
- [Building a receiver API](#building-a-receiver-api)
- [Prometheus scrape endpoint](#prometheus-scrape-endpoint)
- [Configuration](#configuration)

---

## Concepts

A **scheduler** is an independent webhook target with its own settings:

| Field | Description |
|---|---|
| `name` | Human readable label. |
| `webhook_url` | The HTTP(S) endpoint that receives the push (`POST`). |
| `secret_key` | Optional secret used to authenticate/sign the request. |
| `interval` | Send interval in seconds (minimum `PUSH_SCHEDULER_MIN_INTERVAL`, default 10). |
| `is_enabled` | Enable/disable sending without deleting the scheduler. |
| `include_users` | Whether the full users array is included in the payload. |

You can create **N schedulers**, each pointing to a different webhook, with its
own interval and secret. A background manager reconciles the live jobs with the
database every `JOB_SYNC_PUSH_SCHEDULERS_INTERVAL` seconds (and immediately when
you change something through the API), so enabling, disabling, re-intervaling and
deleting all take effect at runtime without restarting Marzban.

Metrics collection is intentionally cheap: a handful of aggregate SQL queries
(no per-user N+1) plus non-blocking `psutil` sampling, and a short-lived snapshot
cache (`PUSH_METRICS_CACHE_TTL`) shared between schedulers firing at the same
time. Enabling push metrics does not slow down the API.

---

## Managing schedulers via the API

All endpoints require a **sudo admin** bearer token (the same token used by the
rest of the admin API). Base prefix: `/api/notification`.

| Method | Path | Description |
|---|---|---|
| `GET` | `/api/notification/schedulers` | List all schedulers with status info. |
| `POST` | `/api/notification/schedulers` | Create a scheduler. |
| `GET` | `/api/notification/schedulers/{id}` | Get a single scheduler. |
| `PUT` | `/api/notification/schedulers/{id}` | Modify a scheduler (partial). |
| `DELETE` | `/api/notification/schedulers/{id}` | Delete a scheduler. |
| `POST` | `/api/notification/schedulers/{id}/trigger` | Collect + push immediately (test run). |
| `GET` | `/api/notification/metrics/preview?include_users=true` | Preview the exact JSON payload. |

### Create

```bash
curl -X POST https://your-panel/api/notification/schedulers \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "Prometheus collector",
    "webhook_url": "https://monitoring.example.com/marzban/push",
    "secret_key": "super-secret-token",
    "interval": 60,
    "is_enabled": true,
    "include_users": true
  }'
```

### List (with statuses)

```bash
curl https://your-panel/api/notification/schedulers \
  -H "Authorization: Bearer $TOKEN"
```

Each item includes runtime status: `last_run_at`, `last_status`
(`success`/`failed`/`pending`), `last_status_code`, `last_error`, `total_runs`,
`failed_runs`.

### Update (e.g. change interval / disable)

```bash
curl -X PUT https://your-panel/api/notification/schedulers/1 \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"interval": 30, "is_enabled": false}'
```

To clear the secret key, pass `"secret_key": null`.

### Delete

```bash
curl -X DELETE https://your-panel/api/notification/schedulers/1 \
  -H "Authorization: Bearer $TOKEN"
```

### Test run now

```bash
curl -X POST https://your-panel/api/notification/schedulers/1/trigger \
  -H "Authorization: Bearer $TOKEN"
# -> {"success": true, "status_code": 200, "error": null}
```

---

## Managing schedulers via marzban-cli

Everything available in the API is also available in the CLI:

```bash
marzban cli notification list
marzban cli notification show <id>
marzban cli notification create --name "Prom" --webhook-url "https://.../push" \
    --interval 60 --secret "super-secret-token" --include-users --enabled
marzban cli notification update <id> --interval 30 --disabled
marzban cli notification enable <id>
marzban cli notification disable <id>
marzban cli notification send-now <id>     # test push immediately
marzban cli notification delete <id> -y
```

(When running directly: `marzban-cli.py notification ...`)

---

## Managing schedulers via the dashboard

Open the dashboard, click the **menu (☰)** in the header and choose
**"Notification Settings"** (visible to sudo admins). There you can:

- See every scheduler, its interval and live status badge.
- Add a new scheduler.
- Edit name / URL / secret / interval and toggle *Include users* and *Enabled*.
- **Send now** to test a webhook.
- Delete a scheduler.

The UI follows the existing dashboard styling (Chakra UI, light/dark, i18n).

---

## The push payload

Each push is a single JSON object sent via `POST` with
`Content-Type: application/json`.

```jsonc
{
  "schema_version": "1.0",
  "timestamp": 1750000000.123,        // unix seconds
  "collected_in_ms": 4.21,            // how long collection took
  "instance": "my-server-hostname",
  "scheduler_id": 1,
  "scheduler_name": "Prometheus collector",

  "server": {
    "hostname": "my-server-hostname",
    "cpu_cores": 4,
    "cpu_usage_percent": 12.5,
    "mem_total": 8273043456,
    "mem_used": 3123456789,
    "mem_free": 5149586667,
    "mem_usage_percent": 37.75,
    "disk_total": 84301250560,
    "disk_used": 25600000000,
    "disk_free": 58701250560,
    "disk_usage_percent": 30.4,
    "load_avg_1m": 0.42,
    "load_avg_5m": 0.39,
    "load_avg_15m": 0.35,
    "uptime_seconds": 864000,
    "incoming_bandwidth_speed": 152340,   // bytes/sec (realtime)
    "outgoing_bandwidth_speed": 98230
  },

  "marzban": {
    "version": "0.8.6",
    "total_users": 1250,
    "users_active": 1100,
    "users_disabled": 50,
    "users_expired": 70,
    "users_limited": 25,
    "users_on_hold": 5,
    "online_users": 312,
    "total_incoming_traffic": 9876543210,  // bytes (cumulative uplink)
    "total_outgoing_traffic": 1234567890,  // bytes (cumulative downlink)
    "total_traffic": 11111111100,
    "nodes_total": 3,
    "nodes_connected": 3
  },

  // Prometheus-ready flat samples (name/type/help/value/labels).
  "prometheus": [
    { "name": "marzban_up", "type": "gauge", "help": "...", "value": 1, "labels": {} },
    { "name": "marzban_users_total", "type": "gauge", "help": "...", "value": 1250, "labels": {} },
    { "name": "marzban_users", "type": "gauge", "help": "...", "value": 1100, "labels": { "status": "active" } },
    { "name": "marzban_online_users", "type": "gauge", "help": "...", "value": 312, "labels": {} },
    { "name": "marzban_cpu_usage_percent", "type": "gauge", "help": "...", "value": 12.5, "labels": {} }
    // ... ~28 samples total
  ],

  // Present only when include_users = true.
  "users": [
    {
      "username": "john",
      "status": "active",
      "used_traffic": 5368709120,
      "lifetime_used_traffic": 10737418240,
      "data_limit": 53687091200,
      "data_limit_reset_strategy": "no_reset",
      "expire": 1760000000,
      "online_at": "2026-06-20T12:34:56",
      "created_at": "2026-01-01T00:00:00",
      "admin": "superadmin"
    }
  ]
}
```

### Why two metric representations?

- The nested `server` / `marzban` objects are convenient for general-purpose
  consumers, dashboards, n8n flows, Grafana Infinity, etc.
- The `prometheus` array maps 1:1 to Prometheus samples. Your receiver can turn
  it into the Prometheus text exposition format trivially (or feed it to a
  Pushgateway / remote-write proxy). The same metric set is also available via
  the pull-based [`/api/metrics`](#prometheus-scrape-endpoint) endpoint.

---

## Verifying the request (secret key + HMAC)

When a scheduler has a `secret_key`, two headers are added to every request:

| Header | Value |
|---|---|
| `X-Webhook-Secret` | The raw secret key (simple shared-secret check). |
| `X-Signature-256` | `sha256=<hex>` HMAC-SHA256 of the **raw request body** keyed by the secret. |

Always verify against the **raw bytes** of the body (before JSON parsing).

### Python (FastAPI) verification

```python
import hmac, hashlib
from fastapi import FastAPI, Request, HTTPException

SECRET = b"super-secret-token"
app = FastAPI()

@app.post("/marzban/push")
async def receive(request: Request):
    raw = await request.body()

    # Option A: shared secret
    if request.headers.get("x-webhook-secret") != SECRET.decode():
        raise HTTPException(401, "bad secret")

    # Option B: HMAC signature (recommended)
    expected = "sha256=" + hmac.new(SECRET, raw, hashlib.sha256).hexdigest()
    if not hmac.compare_digest(expected, request.headers.get("x-signature-256", "")):
        raise HTTPException(401, "bad signature")

    payload = await request.json()
    # ... handle payload["server"], payload["marzban"], payload["users"] ...
    return {"ok": True}
```

### Node.js (Express) verification

```js
const express = require("express");
const crypto = require("crypto");

const SECRET = "super-secret-token";
const app = express();

// keep the raw body for signature verification
app.use(express.json({ verify: (req, _res, buf) => { req.rawBody = buf; } }));

app.post("/marzban/push", (req, res) => {
  const expected =
    "sha256=" + crypto.createHmac("sha256", SECRET).update(req.rawBody).digest("hex");
  const got = req.headers["x-signature-256"] || "";
  if (
    expected.length !== got.length ||
    !crypto.timingSafeEqual(Buffer.from(expected), Buffer.from(got))
  ) {
    return res.status(401).json({ error: "bad signature" });
  }
  const payload = req.body;
  // ... handle payload ...
  res.json({ ok: true });
});

app.listen(8799);
```

A response with any 2xx status code is treated as success.

---

## Building a receiver API

### Example: push → Prometheus exposition (Flask + Pushgateway-like)

```python
from flask import Flask, request, Response

app = Flask(__name__)
latest = {"text": ""}

@app.post("/marzban/push")
def push():
    payload = request.get_json()
    lines, seen = [], set()
    for s in payload.get("prometheus", []):
        if s["name"] not in seen:
            if s.get("help"):
                lines.append(f"# HELP {s['name']} {s['help']}")
            lines.append(f"# TYPE {s['name']} {s['type']}")
            seen.add(s["name"])
        if s.get("labels"):
            lbl = ",".join(f'{k}="{v}"' for k, v in s["labels"].items())
            lines.append(f"{s['name']}{{{lbl}}} {s['value']}")
        else:
            lines.append(f"{s['name']} {s['value']}")
    latest["text"] = "\n".join(lines) + "\n"
    return {"ok": True}

# Point a Prometheus scrape job at this:
@app.get("/metrics")
def metrics():
    return Response(latest["text"], mimetype="text/plain")
```

### Example Grafana setup

- Use the Flask receiver above and scrape its `/metrics` with Prometheus, then
  build Grafana dashboards on `marzban_*` series (e.g. `marzban_online_users`,
  `marzban_users{status="active"}`, `rate(marzban_traffic_bytes_total[5m])`).
- Or push the raw JSON into a store that Grafana can query (Loki/Infinity/ES).

---

## Prometheus scrape endpoint

In addition to push, the same metric set is exposed in the Prometheus text
exposition format (pull model) at:

```
GET /api/metrics        (requires admin bearer token; users array not included)
```

Example Prometheus scrape config:

```yaml
scrape_configs:
  - job_name: marzban
    scheme: https
    metrics_path: /api/metrics
    authorization:
      type: Bearer
      credentials: "YOUR_ADMIN_TOKEN"
    static_configs:
      - targets: ["your-panel:443"]
```

---

## Configuration

These optional environment variables tune the feature (sensible defaults shown):

| Variable | Default | Description |
|---|---|---|
| `PUSH_SCHEDULER_MIN_INTERVAL` | `10` | Minimum allowed scheduler interval (seconds). |
| `JOB_SYNC_PUSH_SCHEDULERS_INTERVAL` | `15` | How often live jobs are reconciled with the DB. |
| `PUSH_METRICS_CACHE_TTL` | `2` | Seconds a metrics snapshot is reused across schedulers. |
| `PUSH_WEBHOOK_TIMEOUT` | `15` | HTTP timeout (seconds) per webhook delivery. |

The schedulers themselves are stored in the database (`notification_schedulers`
table, added by Alembic migration `f1a2b3c4d5e6`) and managed at runtime — no
env configuration is required to use the feature.
