# USAGE-ADD-PUSH — API reference for building a push-scheduler management module

This document is a complete, implementation-ready reference of the **push
notification scheduler** API. It is written so you (or an AI/codegen tool) can
build a standalone module/SDK that creates and manages schedulers on a Marzban
panel.

For the conceptual overview, payload schema and webhook-receiver examples, see
[`USAGE-PUSH.md`](./USAGE-PUSH.md). This file focuses on the **management API**.

> Minimum scheduler interval is **5 seconds** (`PUSH_SCHEDULER_MIN_INTERVAL`,
> default `5`). Values below the configured minimum are rejected with `422`.

---

## 1. Base URL & versioning

```
BASE_URL = https://<panel-host>[:port]/api
```

All scheduler endpoints live under `BASE_URL/notification`. There is no API
versioning header; the payload object carries `schema_version` instead.

---

## 2. Authentication

All scheduler endpoints require a **sudo admin** JWT bearer token.

### 2.1 Obtain a token

`POST /api/admin/token` — `application/x-www-form-urlencoded` (OAuth2 password flow).

| Form field | Required | Notes |
|---|---|---|
| `username` | yes | Sudo admin username. |
| `password` | yes | Sudo admin password. |
| `grant_type` | no | `password` (optional). |

**Response `200`:**

```json
{ "access_token": "eyJhbGciOi...", "token_type": "bearer" }
```

**Errors:** `401 Incorrect username or password`.

```bash
curl -X POST "$BASE_URL/admin/token" \
  -d "username=admin" -d "password=secret"
```

### 2.2 Use the token

Send on every request:

```
Authorization: Bearer <access_token>
```

If the admin is not sudo, scheduler endpoints return `403`. If the token is
missing/invalid, they return `401`.

---

## 3. The Scheduler resource

### 3.1 Object schema (response)

```jsonc
{
  "id": 1,                          // int, server-assigned
  "name": "Prometheus collector",   // string 1..128
  "webhook_url": "https://...",     // string 1..1024, must start with http:// or https://
  "secret_key": "super-secret",     // string|null, max 256
  "interval": 60,                   // int >= 5 (seconds)
  "is_enabled": true,               // bool
  "include_users": true,            // bool

  // runtime status (read-only)
  "last_run_at": "2026-06-22T01:00:00",  // ISO datetime | null
  "last_status": "success",              // "success" | "failed" | "pending" | null
  "last_status_code": 200,               // int | null (HTTP status returned by the webhook)
  "last_error": null,                    // string | null (set when last_status == "failed")
  "total_runs": 42,                      // int
  "failed_runs": 1,                      // int
  "created_at": "2026-06-20T18:30:00",   // ISO datetime | null
  "updated_at": "2026-06-22T01:00:00"    // ISO datetime | null
}
```

### 3.2 Field constraints & validation

| Field | Type | Create | Update | Rules |
|---|---|---|---|---|
| `name` | string | required | optional | length 1–128 |
| `webhook_url` | string | required | optional | length 1–1024, **must** start with `http://` or `https://` (trimmed) |
| `secret_key` | string\|null | optional | optional | max 256; pass `null` to clear |
| `interval` | int | optional (def `60`) | optional | `>= 5` (or configured `PUSH_SCHEDULER_MIN_INTERVAL`) |
| `is_enabled` | bool | optional (def `true`) | optional | — |
| `include_users` | bool | optional (def `true`) | optional | — |

All status fields (`last_*`, `total_runs`, `failed_runs`, timestamps, `id`) are
**read-only** and ignored if sent in a request body.

---

## 4. Endpoints

Prefix for all: `BASE_URL/notification`.

| # | Method | Path | Purpose |
|---|---|---|---|
| 4.1 | `GET` | `/schedulers` | List all schedulers + status |
| 4.2 | `POST` | `/schedulers` | Create a scheduler |
| 4.3 | `GET` | `/schedulers/{id}` | Get one scheduler |
| 4.4 | `PUT` | `/schedulers/{id}` | Partially update a scheduler |
| 4.5 | `DELETE` | `/schedulers/{id}` | Delete a scheduler |
| 4.6 | `POST` | `/schedulers/{id}/trigger` | Collect & push now (test run) |
| 4.7 | `GET` | `/metrics/preview` | Preview the JSON payload |

Common error responses for all of the above: `401` (unauthenticated), `403`
(not sudo), `422` (validation error). `{id}` endpoints add `404`.

---

### 4.1 List schedulers

`GET /notification/schedulers`

**Response `200`:** array of [Scheduler objects](#31-object-schema-response).

```bash
curl "$BASE_URL/notification/schedulers" -H "Authorization: Bearer $TOKEN"
```

---

### 4.2 Create a scheduler

`POST /notification/schedulers` — `application/json`

**Request body:**

```json
{
  "name": "Prometheus collector",
  "webhook_url": "https://monitoring.example.com/marzban/push",
  "secret_key": "super-secret-token",
  "interval": 60,
  "is_enabled": true,
  "include_users": true
}
```

Minimal body: `{ "name": "...", "webhook_url": "https://..." }` (other fields
default to `secret_key=null`, `interval=60`, `is_enabled=true`,
`include_users=true`).

**Response `200`:** the created Scheduler object (with `id`).

**Errors:** `422` if `webhook_url` scheme is invalid or `interval < 5`.

```bash
curl -X POST "$BASE_URL/notification/schedulers" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"name":"Prom","webhook_url":"https://mon.example.com/push","interval":15}'
```

---

### 4.3 Get one scheduler

`GET /notification/schedulers/{id}`

**Response `200`:** Scheduler object. **`404`** if not found.

---

### 4.4 Update a scheduler (partial)

`PUT /notification/schedulers/{id}` — `application/json`

Send only the fields you want to change. Omitted fields are unchanged.

```json
{ "interval": 30, "is_enabled": false }
```

- To **disable** without deleting: `{ "is_enabled": false }`
- To **enable**: `{ "is_enabled": true }`
- To **clear the secret**: `{ "secret_key": null }`
- To **change the target**: `{ "webhook_url": "https://new/url" }`

**Response `200`:** updated Scheduler object. **`404`** if not found, **`422`**
on invalid values.

```bash
curl -X PUT "$BASE_URL/notification/schedulers/1" \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"interval":30,"is_enabled":false}'
```

---

### 4.5 Delete a scheduler

`DELETE /notification/schedulers/{id}`

**Response `200`:** `{ "detail": "Scheduler successfully deleted" }`. **`404`**
if not found.

```bash
curl -X DELETE "$BASE_URL/notification/schedulers/1" \
  -H "Authorization: Bearer $TOKEN"
```

---

### 4.6 Trigger now (test run)

`POST /notification/schedulers/{id}/trigger`

Immediately collects metrics and pushes once, regardless of `is_enabled`.
Updates the scheduler's status fields. Use for "Test webhook" buttons.

**Response `200`:**

```json
{ "success": true, "status_code": 200, "error": null }
```

`success` reflects whether the webhook responded 2xx. **`404`** if not found.

```bash
curl -X POST "$BASE_URL/notification/schedulers/1/trigger" \
  -H "Authorization: Bearer $TOKEN"
```

---

### 4.7 Preview payload

`GET /notification/metrics/preview?include_users=true`

Returns the exact JSON object that would be pushed (no webhook is called). Use
it to render previews or validate your receiver.

| Query param | Type | Default |
|---|---|---|
| `include_users` | bool | `true` |

**Response `200`:** a `PushMetricsPayload` object (see
[`USAGE-PUSH.md` → The push payload](./USAGE-PUSH.md#the-push-payload)).

---

## 5. Behaviour notes for client modules

- **Runtime apply:** create/update/delete take effect within a few seconds (an
  immediate reconcile is requested on each mutation; a periodic reconciler runs
  every `JOB_SYNC_PUSH_SCHEDULERS_INTERVAL` seconds as backup). No restart.
- **First push:** after enabling, the first push fires ~5s later, then every
  `interval` seconds.
- **Status polling:** to show live status, poll `GET /schedulers` (the dashboard
  refreshes every 5s while open). Watch `last_status`, `last_status_code`,
  `last_error`, `total_runs`, `failed_runs`.
- **Secret/signature:** if `secret_key` is set, each push carries
  `X-Webhook-Secret: <secret>` and `X-Signature-256: sha256=<hmac>` (HMAC-SHA256
  of the raw body). Verify against raw bytes (see `USAGE-PUSH.md`).
- **N webhooks:** create one scheduler per webhook; each is fully independent
  (own URL, interval, secret, `include_users`).
- **Idempotency:** there is no upsert; creating twice yields two rows. Track
  `id` client-side. `name` is **not** unique.

---

## 6. Reference client module (Python)

A minimal SDK you can drop into a management module:

```python
import requests


class MarzbanPushClient:
    def __init__(self, base_url: str, username: str, password: str, verify=True):
        self.base = base_url.rstrip("/")          # e.g. https://panel/api
        self.s = requests.Session()
        self.s.verify = verify
        self._login(username, password)

    def _login(self, username, password):
        r = self.s.post(f"{self.base}/admin/token",
                        data={"username": username, "password": password})
        r.raise_for_status()
        token = r.json()["access_token"]
        self.s.headers["Authorization"] = f"Bearer {token}"

    # --- scheduler management ---
    def list(self):
        return self.s.get(f"{self.base}/notification/schedulers").json()

    def get(self, sid: int):
        return self.s.get(f"{self.base}/notification/schedulers/{sid}").json()

    def create(self, name, webhook_url, interval=60, secret_key=None,
               is_enabled=True, include_users=True):
        body = {"name": name, "webhook_url": webhook_url, "interval": interval,
                "secret_key": secret_key, "is_enabled": is_enabled,
                "include_users": include_users}
        r = self.s.post(f"{self.base}/notification/schedulers", json=body)
        r.raise_for_status()
        return r.json()

    def update(self, sid: int, **fields):
        # only pass fields you want to change, e.g. interval=5, is_enabled=False
        r = self.s.put(f"{self.base}/notification/schedulers/{sid}", json=fields)
        r.raise_for_status()
        return r.json()

    def enable(self, sid):  return self.update(sid, is_enabled=True)
    def disable(self, sid): return self.update(sid, is_enabled=False)

    def delete(self, sid: int):
        r = self.s.delete(f"{self.base}/notification/schedulers/{sid}")
        r.raise_for_status()
        return r.json()

    def trigger(self, sid: int):
        r = self.s.post(f"{self.base}/notification/schedulers/{sid}/trigger")
        r.raise_for_status()
        return r.json()

    def preview(self, include_users=True):
        return self.s.get(f"{self.base}/notification/metrics/preview",
                          params={"include_users": str(include_users).lower()}).json()


# Example
if __name__ == "__main__":
    c = MarzbanPushClient("https://panel.example.com/api", "admin", "secret")
    s = c.create("Prometheus", "https://mon.example.com/push", interval=5,
                 secret_key="topsecret")
    print("created", s["id"])
    print(c.trigger(s["id"]))
    print(c.list())
```

### TypeScript types

```ts
export interface NotificationScheduler {
  id: number;
  name: string;
  webhook_url: string;
  secret_key: string | null;
  interval: number;            // >= 5
  is_enabled: boolean;
  include_users: boolean;
  last_run_at: string | null;
  last_status: "success" | "failed" | "pending" | null;
  last_status_code: number | null;
  last_error: string | null;
  total_runs: number;
  failed_runs: number;
  created_at: string | null;
  updated_at: string | null;
}

export interface SchedulerCreate {
  name: string;
  webhook_url: string;
  secret_key?: string | null;
  interval?: number;           // default 60, min 5
  is_enabled?: boolean;        // default true
  include_users?: boolean;     // default true
}

export type SchedulerModify = Partial<SchedulerCreate>;

export interface TriggerResult {
  success: boolean;
  status_code: number | null;
  error: string | null;
}
```

---

## 7. CLI equivalents (for server-side automation)

Every API action has a `marzban-cli` counterpart:

```bash
marzban cli notification list
marzban cli notification show <id>
marzban cli notification create --name N --webhook-url URL --interval 5 \
    --secret S --include-users --enabled
marzban cli notification update <id> --interval 5 --disabled
marzban cli notification enable <id>
marzban cli notification disable <id>
marzban cli notification send-now <id>
marzban cli notification delete <id> -y
```

---

## 8. Quick HTTP status reference

| Code | Meaning |
|---|---|
| `200` | Success |
| `401` | Missing/invalid token |
| `403` | Authenticated but not a sudo admin |
| `404` | Scheduler id not found |
| `422` | Validation error (bad `webhook_url`, `interval < 5`, etc.) |
