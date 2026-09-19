# Bandwidth Blacklist (USAGE-BLACKLIST)

This document describes the **bandwidth blacklist**: a per-user speed cap,
expressed in megabits per second, enforced by the Linux kernel on the panel
host.

A user on the blacklist is not blocked and not disabled — it keeps working,
just slower. The cap applies to each direction separately: `limit_mbps: 10`
means up to 10 Mbit/s down **and** up to 10 Mbit/s up.

Caps come from two places: an operator, and — when automatic throttling is
enabled — the anomaly monitor
([`USAGE-ANOMALY.md`](USAGE-ANOMALY.md#throttling-offenders-automatically)).
Both live in the same table and are enforced identically; see
[Manual caps and automatic ones](#manual-caps-and-automatic-ones).

It is fully additive. With an empty blacklist nothing is installed in the
kernel and a tick costs one indexed `SELECT`; the rest of the panel is
untouched, so an existing installation can be upgraded and the feature simply
left unused.

---

## Contents

- [How the cap is enforced](#how-the-cap-is-enforced)
- [Manual caps and automatic ones](#manual-caps-and-automatic-ones)
- [Requirements](#requirements)
- [Managing the blacklist via the API](#managing-the-blacklist-via-the-api)
- [Managing the blacklist via the dashboard](#managing-the-blacklist-via-the-dashboard)
- [Enforcement status](#enforcement-status)
- [Lifecycle and cleanup](#lifecycle-and-cleanup)
- [Configuration](#configuration)
- [Limits and caveats](#limits-and-caveats)

---

## How the cap is enforced

Xray has no per-user rate limit, so the cap is applied below it, on the
interface that carries the tunnel.

Every `JOB_SYNC_BLACKLIST_INTERVAL` seconds (10 by default) the job
`app/jobs/sync_blacklist.py`:

1. reads the enabled entries — one indexed `SELECT`;
2. asks the local core which source addresses those users are connected from
   (the same online-IP RPCs the anomaly monitor uses, one gRPC call when the
   core supports the bulk RPC);
3. hands the pairs *(address, cap)* to `app/utils/shaper.py`, which rewrites
   the kernel rules — but only when that set actually changed.

The shaper installs, on the interface of the default route:

| direction | mechanism |
|---|---|
| download | `htb` root qdisc, one class per capped user with `fq_codel` as its leaf, `u32` filters on the destination address |
| upload | `ingress` qdisc, `u32` filters on the source address with a policer |

The download side is queued (shaped), the upload side is policed: queueing
inbound traffic would require an `ifb` device, while dropping over-rate
packets is enough for TCP to settle at the cap. Uncapped traffic falls into a
catch-all class at `BLACKLIST_LINK_MBPS`.

An address stays shaped for `BLACKLIST_IP_TTL` seconds after the user was
last seen using it, so a quiet client does not flap in and out of the rules.
If two capped users share an address (household NAT, a shared subscription),
the strictest cap wins it.

## Manual caps and automatic ones

Every entry carries a `source` and an `expires_at`:

| `source` | `expires_at` | Who owns it |
|---|---|---|
| `manual` | `null` | an operator, through the API, CLI or dashboard; it stays until removed by hand |
| `anomaly` | a timestamp | the anomaly monitor; it lifts itself when the time is up |

The rules that keep the two from fighting:

- The monitor never touches an entry whose `source` is `manual` — an
  operator's decision outranks the automation.
- `PUT /api/blacklist/{username}` on an automatic entry (including the Save
  button in the dashboard) makes it `manual` and clears `expires_at`: you
  touched it, so it is yours now and the monitor leaves it alone.
- `DELETE` lifts an automatic cap early. If the user is still anomalous, the
  monitor will install a new one on its next tick.
- The reconciler stops enforcing a cap the moment it expires and deletes the
  row in the same pass — including while monitoring is switched off, so an
  automatic cap can never outlive the feature that created it.

The dashboard marks automatic entries with an **авто** badge and the time they
lift.

## Requirements

- The panel container must have the `NET_ADMIN` capability and the host
  network namespace (`network_mode: host`, which is how Marzban runs by
  default):

  ```yaml
  services:
    marzban:
      cap_add:
        - NET_ADMIN
  ```

  `marzban update` (`sauceme.sh`) adds the capability to an existing
  `docker-compose.yml` if it is missing. Without it the entries are kept, the
  API keeps answering, and `status.unavailable_reason` says what to fix.

- `iproute2` (the `tc` utility) — already in the image.

- A core that reports online IPs (`statsUserOnline`, forced on in
  `app/xray/config.py`). Without it the caps cannot be mapped to addresses and
  `status.ip_source` stays `unavailable`.

- The interface must not already be shaped by something else. A foreign root
  qdisc is never replaced: the feature stays out of the way and reports why.

## Managing the blacklist via the API

All endpoints require a **sudo admin** token.

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/api/blacklist` | all entries + enforcement status |
| `GET` | `/api/blacklist/status` | enforcement status alone (cheap to poll) |
| `POST` | `/api/blacklist` | cap a user |
| `GET` | `/api/blacklist/{username}` | one entry |
| `PUT` | `/api/blacklist/{username}` | change cap / suspend / edit reason |
| `DELETE` | `/api/blacklist/{username}` | lift the cap |

Capping a user:

```bash
curl -X POST https://panel.example.com/api/blacklist \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"username": "heavy_torrenter", "limit_mbps": 10, "reason": "uplink"}'
```

```json
{
  "id": 1,
  "user_id": 42,
  "username": "heavy_torrenter",
  "limit_mbps": 10,
  "is_enabled": true,
  "reason": "uplink",
  "source": "manual",
  "expires_at": null,
  "created_at": "2026-09-19T12:00:00",
  "updated_at": "2026-09-19T12:00:00",
  "active_ips": [],
  "shaped_bytes": 0,
  "dropped_packets": 0
}
```

`active_ips`, `shaped_bytes` and `dropped_packets` are live state read from
the kernel, not columns: the addresses the cap is installed for right now,
the bytes that went through the user's class and the packets the cap cost it.
They stay empty until the user actually connects and the next sync runs
(within `JOB_SYNC_BLACKLIST_INTERVAL` seconds).

Raising the cap or suspending it without losing the entry:

```bash
curl -X PUT https://panel.example.com/api/blacklist/heavy_torrenter \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"limit_mbps": 50}'

curl -X PUT https://panel.example.com/api/blacklist/heavy_torrenter \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"is_enabled": false}'
```

A disabled entry is bookkeeping only: its rules are removed from the kernel
and the user runs at full speed until it is enabled again.

Every mutation queues an immediate reconciliation, so a change lands in about
a second instead of waiting for the next tick. The API itself never waits for
`tc`.

`limit_mbps` is an integer between 1 and `BLACKLIST_MAX_MBPS`. Adding a user
that is already on the list answers `409`, an unknown username `404`.

## Managing the blacklist via the dashboard

Menu → **Чёрный список**. The dialog lists the capped users with their limit
and live state (`лимит на N IP` / `не в сети` / `выключено`), lets you add a
user with autocomplete over usernames, change a limit, suspend an entry or
remove it. When enforcement is off or broken, the dialog says so at the top
instead of silently showing caps that do nothing.

## Enforcement status

`GET /api/blacklist/status`:

```json
{
  "enforce": true,
  "available": true,
  "unavailable_reason": null,
  "interface": "ens3",
  "ip_source": "bulk",
  "entries_total": 2,
  "shaped_users": 1,
  "shaped_ips": 2,
  "last_sync_at": 1789833162.5,
  "last_applied_at": 1789833152.5,
  "last_error": null
}
```

- `enforce` — the `BLACKLIST_ENFORCE` switch.
- `available` / `unavailable_reason` — whether the kernel rules can be
  installed, and what to fix if not (missing `NET_ADMIN`, no `tc`, a foreign
  qdisc on the interface).
- `ip_source` — how the addresses are read: `bulk` (one RPC), `probe` (per
  user, older cores) or `unavailable`. With an empty blacklist nothing is
  polled and it stays `unavailable` — that is not an error.
- `shaped_users` / `shaped_ips` — what is installed right now, which is less
  than `entries_total` when a capped user is offline.

## Lifecycle and cleanup

- Deleting a user deletes its blacklist entry (`ON DELETE CASCADE` plus the
  ORM relationship), and the next sync drops the matching kernel rules.
- An automatic cap is deleted when it expires, by the same job.
- Removing the last entry restores the interface to the qdisc it had before.
- Restarting the panel re-derives everything from the table; leftovers from a
  previous process are cleaned before the rules are installed again.

## Configuration

| Variable | Default | Meaning |
|---|---|---|
| `JOB_SYNC_BLACKLIST_INTERVAL` | `10` | seconds between reconciliations |
| `BLACKLIST_ENFORCE` | `True` | apply the caps; off = bookkeeping only |
| `BLACKLIST_INTERFACE` | *(empty)* | interface to shape; empty = default route |
| `BLACKLIST_LINK_MBPS` | `10000` | rate of the catch-all class, keep at or above the real link speed |
| `BLACKLIST_IP_TTL` | `180` | seconds an address keeps being shaped after the user was last seen on it |
| `BLACKLIST_MAX_MBPS` | `10000` | highest cap the API accepts |
| `BLACKLIST_STATS_TIMEOUT` | `10` | gRPC timeout for reading online IPs |
| `BLACKLIST_TC_TIMEOUT` | `10` | timeout for one `tc` invocation |

## Limits and caveats

- **Panel host only.** Traffic of a user connected through a remote Marzban
  node never passes through this host, so nothing here can shape it; that
  would need an agent on the node.
- **Per address, not per connection.** The cap is enforced on the addresses
  the user connects from. A user behind carrier-grade NAT shares its address
  with strangers only if they hit the same panel — in that case the strictest
  cap applies to everyone behind it.
- **Reaction time.** A newly connected user is capped within one sync
  interval, not instantly.
- The feature owns the root qdisc of the interface while at least one cap is
  active. Hand-made `tc` rules on that interface will be removed; class minor
  ids `0x1`–`0xf` are left free for an operator that needs them.
