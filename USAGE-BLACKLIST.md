# Bandwidth Limits (USAGE-BLACKLIST)

This document describes the **bandwidth limits**, a speed cap in megabits per
second enforced by the Linux kernel on the panel host. There are two of them
and they are independent:

| | [The blacklist](#how-the-cap-is-enforced) | [The limit for everyone](#the-limit-for-everyone) |
|---|---|---|
| applies to | the users you (or the anomaly monitor) name | every client address |
| the unit that gets the cap | a user, with all its addresses | one address |
| stored in | `blacklist_users`, a row per user | `bandwidth_settings`, one row |
| enforced with | `tc` (queued download, policed upload) | `nft` (policed both ways) |
| costs | a class and filters per capped address | two rules and a bucket per active address |

Both are additive and off until used: an empty blacklist installs nothing, the
limit for everyone is disabled by default, and the rest of the panel is
untouched — an existing installation can be upgraded and neither feature used.

A user is never blocked or disabled by either, it just goes slower. Both caps
apply to each direction separately: `limit_mbps: 10` means up to 10 Mbit/s down
**and** up to 10 Mbit/s up. When both are in force, the stricter one wins.

Blacklist caps come from two places: an operator, and — when automatic
throttling is enabled — the anomaly monitor
([`USAGE-ANOMALY.md`](USAGE-ANOMALY.md#throttling-offenders-automatically)).
Both live in the same table and are enforced identically; see
[Manual caps and automatic ones](#manual-caps-and-automatic-ones).

---

## Contents

- [How the cap is enforced](#how-the-cap-is-enforced)
- [Manual caps and automatic ones](#manual-caps-and-automatic-ones)
- [The limit for everyone](#the-limit-for-everyone)
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

## The limit for everyone

The blacklist names its users, so the panel can afford to learn where each of
them connects from and build `tc` rules for those addresses. A cap that applies
to *everyone* cannot work that way: it would mean a class per online address,
rewritten whenever anybody connects, and a list of online addresses polled from
the core just to build it.

So the kernel keeps that state instead. Two `nft` rules — one per direction —
update a dynamic set keyed by the client address, with a rate limit attached to
every element:

```
ct direction reply update @down4 { ip daddr limit rate over 25000000 bytes/second } drop
```

`ct direction` is what makes the address in the rule a *client's*. Both a client
and a site the panel fetched for it are on the far side of this interface, and
the client is the one that opened the connection: its packets are the original
direction coming in and the reply direction going out. Without that test the
data coming back from a site is bucketed by the *site's* address, so everyone
downloading from the same host — or, on a panel that chains to an upstream
server, simply everyone — shares one bucket instead of getting one each.

The first packet of an address creates its token bucket, packets over the rate
are dropped, and an address that goes quiet is forgotten after
`GLOBAL_LIMIT_IP_TIMEOUT` seconds. That is a hash lookup per packet and about a
hundred bytes per active address, the same whether ten or ten thousand clients
are online, and the panel process never learns who is online at all: nothing is
polled, and `nft` is only called when the setting changes.

**The cap is per address, and each address gets the whole of it.**
`global_mbps: 200` means every client address may do 200 Mbit/s in each
direction — it is not 200 Mbit/s shared between them. A user with a phone and a
laptop gets 200 on each; devices behind one NAT address share one 200.

```bash
curl -X PUT https://panel.example.com/api/blacklist/settings \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"global_enabled": true, "global_mbps": 200}'
```

```json
{
  "global_enabled": true,
  "global_mbps": 200,
  "available": true,
  "unavailable_reason": null,
  "interface": "ens3",
  "dropped_packets_down": 0,
  "dropped_packets_up": 0,
  "last_applied_at": 1789833152.5,
  "last_error": null
}
```

`GET /api/blacklist/settings` reads the same object; the switch and the rate are
also in `status.global_limit` of `GET /api/blacklist`, so the dashboard gets
everything in one request. `global_mbps` is an integer between 1 and
`BLACKLIST_MAX_MBPS`. A change takes effect in about a second, through the same
queued reconciliation the blacklist uses.

What is worth knowing before switching it on:

- **The two limits compose, they do not replace each other.** A blacklisted user
  is shaped by `tc` *and* policed by `nft`, so it runs at the stricter of the
  two. Raising someone's blacklist cap above `global_mbps` does not make it
  faster than everyone else.
- **Both directions are policed**, i.e. over-rate packets are dropped rather
  than queued. Queueing a download needs a queue per address, which is the very
  thing this avoids. TCP settles at the cap on its own, at the price of some
  retransmissions — the same trade the upload side of the blacklist already
  makes.
- **It covers everything that connects to the panel**, not only the tunnels:
  the rules match on addresses, not on Xray's ports, so an SSH session or the
  dashboard is capped per address too. What the panel dials out itself — a
  node link, a database, an update — is not capped, because there the far end
  is not a client. Loopback and the docker bridges are never touched.
- **Untracked traffic escapes the cap.** Telling a client from a site needs
  connection tracking; a `notrack` rule in the raw table would make the
  metering rules skip that traffic entirely.
- **Changing the rate resets the buckets.** The table is replaced as a whole, so
  every tracked address is forgotten and its cap starts fresh.
- **The rules are checked once a minute.** A `nft flush ruleset` from an
  unrelated firewall script takes them with it; the next check notices and puts
  them back.

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

- `iproute2` (the `tc` utility) and `nftables` (the `nft` utility) — both are
  already in the image. `nft` is only needed for the limit for everyone, `tc`
  only for the blacklist, so a host missing one keeps the other working.

- A core that reports online IPs (`statsUserOnline`, forced on in
  `app/xray/config.py`). Needed by the blacklist, which has to map its caps to
  addresses; without it `status.ip_source` stays `unavailable`. The limit for
  everyone does not use the core at all.

- The interface must not already be shaped by something else. A foreign root
  qdisc is never replaced: the feature stays out of the way and reports why.
  This applies to the blacklist only — the limit for everyone installs its own
  `nft` table and leaves an existing firewall alone.

## Managing the blacklist via the API

All endpoints require a **sudo admin** token.

| Method | Path | Purpose |
|---|---|---|
| `GET` | `/api/blacklist` | all entries + enforcement status |
| `GET` | `/api/blacklist/status` | enforcement status alone (cheap to poll) |
| `GET` | `/api/blacklist/settings` | the limit for everyone |
| `PUT` | `/api/blacklist/settings` | turn the limit for everyone on/off, change its rate |
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

Menu → **Лимиты канала**. One dialog holds both limits.

At the top, **Лимит всем сразу**: a switch, the rate each address gets, and how
many packets the cap has dropped since it was installed. When it is on but
cannot be applied, the reason is shown right there instead of a switch that
quietly does nothing.

Below, **Лимиты отдельным пользователям**: the capped users with their limit and
live state (`лимит на N IP` / `не в сети` / `выключено`), a form to add a user
with autocomplete over usernames, and per entry a way to change the limit,
suspend it or remove it. When enforcement is off or broken, the dialog says so at
the top instead of silently showing caps that do nothing.

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
  "last_error": null,
  "global_limit": {
    "global_enabled": true,
    "global_mbps": 200,
    "available": true,
    "unavailable_reason": null,
    "interface": "ens3",
    "dropped_packets_down": 154,
    "dropped_packets_up": 12,
    "last_applied_at": 1789833152.5,
    "last_error": null
  }
}
```

- `enforce` — the `BLACKLIST_ENFORCE` switch, which covers both limits.
- `available` / `unavailable_reason` — whether the kernel rules can be
  installed, and what to fix if not (missing `NET_ADMIN`, no `tc`, a foreign
  qdisc on the interface).
- `ip_source` — how the addresses are read: `bulk` (one RPC), `probe` (per
  user, older cores) or `unavailable`. With an empty blacklist nothing is
  polled and it stays `unavailable` — that is not an error.
- `shaped_users` / `shaped_ips` — what is installed right now, which is less
  than `entries_total` when a capped user is offline.
- `global_limit` — the limit for everyone, with its own `available` /
  `unavailable_reason` (missing `NET_ADMIN`, no `nft`, a kernel without dynamic
  sets) and the packets it has dropped in each direction. The counters restart
  from zero whenever the rules are installed again.

## Lifecycle and cleanup

- Deleting a user deletes its blacklist entry (`ON DELETE CASCADE` plus the
  ORM relationship), and the next sync drops the matching kernel rules.
- An automatic cap is deleted when it expires, by the same job.
- Removing the last entry restores the interface to the qdisc it had before.
- Restarting the panel re-derives everything from the database; leftovers from a
  previous process are cleaned before the rules are installed again — including
  the `nft` table when the limit for everyone is off, so switching it off and
  restarting cannot leave a forgotten cap behind.
- Turning the limit for everyone off deletes its table as a whole, and with it
  every bucket the kernel was holding.

## Configuration

The limit for everyone is configured through the API, the dashboard and the
database (`bandwidth_settings`, added by Alembic migration `e5f6a7b8c9d0`) — it
has no environment variable of its own on purpose: an operator turns a
panel-wide speed limit on and off while watching the server, not by redeploying.

These variables tune the plumbing of both limits:

| Variable | Default | Meaning |
|---|---|---|
| `JOB_SYNC_BLACKLIST_INTERVAL` | `10` | seconds between reconciliations |
| `BLACKLIST_ENFORCE` | `True` | apply the caps at all; off = bookkeeping only, for both limits |
| `BLACKLIST_INTERFACE` | *(empty)* | interface to shape; empty = default route |
| `BLACKLIST_LINK_MBPS` | `10000` | rate of the catch-all class, keep at or above the real link speed |
| `BLACKLIST_IP_TTL` | `180` | seconds an address keeps being shaped after the user was last seen on it |
| `BLACKLIST_MAX_MBPS` | `10000` | highest cap the API accepts |
| `BLACKLIST_STATS_TIMEOUT` | `10` | gRPC timeout for reading online IPs |
| `BLACKLIST_TC_TIMEOUT` | `10` | timeout for one `tc` invocation |
| `GLOBAL_LIMIT_IP_TIMEOUT` | `120` | seconds the kernel keeps an address's bucket after its last packet |
| `GLOBAL_LIMIT_MAX_IPS` | `65536` | addresses tracked per direction and address family |
| `GLOBAL_LIMIT_NFT_TIMEOUT` | `10` | timeout for one `nft` invocation |

`BLACKLIST_INTERFACE` (or the default route) is the interface both limits use.

## Limits and caveats

- **Panel host only.** Traffic of a user connected through a remote Marzban
  node never passes through this host, so nothing here can shape it; that
  would need an agent on the node. True for both limits.
- **Per address, not per connection.** Caps are enforced on the addresses the
  user connects from. For the blacklist, a user behind carrier-grade NAT shares
  its address with strangers only if they hit the same panel — in that case the
  strictest cap applies to everyone behind it. For the limit for everyone, one
  address is one cap by definition.
- **Reaction time.** A newly connected user is capped by the blacklist within one
  sync interval, not instantly. The limit for everyone is on it from its first
  packet, because the kernel creates the bucket itself.
- The blacklist owns the root qdisc of the interface while at least one cap is
  active. Hand-made `tc` rules on that interface will be removed; class minor
  ids `0x1`–`0xf` are left free for an operator that needs them.
- The limit for everyone owns the `nft` table `sauceban_bandwidth` and nothing
  else. Do not put your own rules in it: the table is replaced as a whole on
  every change.
- **More addresses than `GLOBAL_LIMIT_MAX_IPS`** means the ones that do not fit
  run uncapped. A full table never blocks anybody.
