# ADR 0001 — Who can read the dashboard, and who may send flows

**Status:** proposed (2026-11-22)
**Covers audit findings:** F-06 (single shared credential, no roles), F-07 (collectors accept flows from anyone)
**Context:** `nfsen-ng-docker` — Caddy (TLS + basic auth) → nfsen-ng → nfdump collectors

## What is actually being protected

Two different things, and they need different answers:

1. **The dashboard** — full read access to flow records: internal topology, address
   plan, DNS activity, per-host traffic patterns. One credential is the whole
   access control today.
2. **The collectors** — `nfcapd`/`sfcapd` listen on UDP with no authentication
   whatsoever. This is not a bug in nfdump: NetFlow v5/v9 and sFlow have no
   authentication in the protocol. Anyone who can reach port 9000-9099 can inject
   fabricated flows (they show up in the UI and are stored until
   `FLOW_RETENTION_DAYS`) or flood the disk and the parser.

## F-06 — dashboard authentication

| Option | MFA | Roles | Revocation | Cost | Notes |
|---|---|---|---|---|---|
| **A. Status quo** — one `basic_auth` user | ✗ | ✗ | change the password for everyone | 0 | Password is sent on every request; browser caches it; no logout. |
| **B. `forward_auth` + self-hosted IdP** (pocket-id, authentik, Keycloak) | ✓ | ✓ | ✓ (per session) | 1 service + ~30 min | Caddy's `forward_auth` calls the IdP per request and copies `X-Auth-Request-User`/`-Groups`; Caddy can then allow/deny per path or role. |
| **C. Network identity** (Tailscale, WireGuard, Cloudflare Access) | depends | ✓ (device) | ✓ | 1 account, 15 min | No app password at all; identity is the device. Breaks the "reach it from any browser on the LAN" model. |
| **D. Add a source-IP allowlist** in front of basic auth | ✗ | ✗ | ✗ | 5 min | Not authentication, but it removes the internet-facing brute-force surface entirely. |

**Recommendation.** Do **D now**, then **B** when a second person needs access (or
when the UI leaves loopback). A stays acceptable only for a single operator on a
single-tenant host — and even then D costs almost nothing.

### D — the exact change (Caddyfile, site block, above `basic_auth`)

```caddyfile
	# Source allowlist. Both families must be listed when this is enabled:
	# a matcher with only IPv4 ranges denies every IPv6 client, including ::1.
	@denied not remote_ip {$ALLOW_CIDR_V4:0.0.0.0/0} {$ALLOW_CIDR_V6:::1/128}
	respond @denied "Forbidden" 403
```

Set both variables in `.env` (`ALLOW_CIDR_V4=192.168.10.0/24`,
`ALLOW_CIDR_V6=::1/128`), then `docker compose up -d --force-recreate caddy`.
Verify from an allowed host (`200`/`401`) **and** from a disallowed one (`403`)
before closing the session — this rule can lock you out.

### B — the shape of it, if chosen

- Run the IdP elsewhere (it must not live behind the thing it protects).
- In Caddy replace `basic_auth` with
  `forward_auth <idp>:4180 { uri /api/verify?rd=https://{$DOMAIN}; copy_headers X-Auth-Request-User X-Auth-Request-Groups }`.
- Keep `basic_auth` **removed**, not layered: two auth prompts in sequence is a
  worse experience than either alone.
- Per-user audit comes free: Caddy logs `{http.auth.user.id}` into the access log,
  which the fail2ban/alerting path already consumes.

## F-07 — collector trust

The protocol cannot authenticate the sender, so the trust boundary has to be the
network. In order of preference:

1. **Bind to the interface the routers use** (`FLOW_BIND_ADDR` in `.env`). Costs
   nothing, removes the wildcard listener, and is already supported. This is the
   only measure that is meaningful on Docker Desktop/Kiri, where there is no
   `iptables`/`nftables` on the host.
2. **Firewall the published range** on a Linux host — see `firewall/nftables-nfsen.nft`
   (the nftables equivalent of the `DOCKER-USER` rule in the README; it must run in
   the `forward` hook to see DNAT'd traffic).
3. **Segment** — export flows over a management VLAN instead of the production one.

Residual risk after 1+2: an attacker on an allowed source IP can still inject
flows. Treat flow data as *untrusted input* for analysis: it is evidence about
the network, not proof. Nothing in this repo can change that without breaking
protocol compatibility — which is precisely why the UI must not be reachable from
the same network that may be hostile (see F-08 in the audit: the compose network
now has no egress, and the UI has its own auth boundary).

## Consequences

- Nothing here adds a runtime dependency; D and 1–2 are configuration only.
- Choosing B later does not invalidate anything built now: Caddy's `forward_auth`
  replaces the `basic_auth` block, and the smoke test's auth assertions move from
  "401 without credentials" to "redirect to the IdP".
- Choosing to do nothing is a decision too: record it here, so the next audit does
  not re-open F-06 as news.
