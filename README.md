# nfsen-ng-docker

Docker setup for running [nfsen-ng](https://github.com/mbolli/nfsen-ng) (NetFlow visualizer) and [nfdump](https://github.com/phaag/nfdump) (NetFlow/sFlow collector) with support for multiple sources.

Runs nfsen-ng **1.0.0-beta.7** — the ground-up rewrite on PHP 8.4 + OpenSwoole. Upstream calls it a beta; pin the tag deliberately (see [Upgrading](#upgrading-from-the-v04-setup)).

## Architecture

```
                    ┌──────────────┐
  HTTP  :8080 ─────►│              │  TLS (self-signed or Let's Encrypt)
                    │    Caddy     │  basic auth, access log (JSON)
  HTTPS :8443 ─────►│              │  security headers
                    └──────┬───────┘
                           │ reverse_proxy (internal network only)
                    ┌──────▼───────┐
                    │    nfsen     │  nfsen-ng: UI + static assets + import
                    │  php-via     │  daemon + SSE, one process on :9000
                    └──┬────────┬──┘
        profiles-data  │        │  nfsen-state (RRD + SQLite)
                    ┌──▼────────▼──┐
  UDP 9000-9099 ───►│   nfdump     │  nfcapd (NetFlow) / sfcapd (sFlow)
                    └──────────────┘
```

- **caddy** — the only entry point. Terminates TLS, enforces basic auth, writes the JSON access log and adds security headers; the other services are reachable only on the internal Docker network.
- **nfsen** — nfsen-ng 1.x on PHP 8.4 + OpenSwoole/php-via. One process serves the UI, its static assets (Brotli-compressed by the app itself), the live SSE stream and the import daemon — no Apache, no php-fpm. Port 9000, not published.

The UI image is built here from the pinned `NFSEN_NG_VERSION` tag, not pulled from ghcr.io: upstream publishes `linux/amd64` only (verified on the `1.0.0-beta.7`, `latest` and `edge` manifest lists), so on Apple Silicon its image cannot run without emulation. Building it locally keeps it native and reproducible, and it compiles the same nfdump 1.7.10 as the collector. On top of upstream's own recipe this repository adds a wrapper that turns `conf/sources.conf` into `NFSEN_SOURCES`.
- **nfdump** — flow collectors (`nfcapd`/`sfcapd`), running as non-root (uid 1000) with a read-only root filesystem, on Debian 13.

**There is exactly one nfdump version in the stack**: the collector compiles 1.7.10 from source and the upstream UI image ships the same 1.7.10 (compiled in), so capture files always match the reader. Both builds assert `nfdump -V`.

## Installation

1. Clone this repository.
2. Create the data directory and make it writable by the collector (uid 1000):
   ```sh
   mkdir -p profiles-data
   docker run --rm -v "$PWD/profiles-data:/data" alpine chown -R 1000:1000 /data
   ```
   (On Linux, `chown -R 1000:1000 profiles-data` works as well.)
3. Configure `conf/sources.conf` — CSV-style, one source per line: `device;port;proto`
   - `device` — display name, e.g. `my-awesome-router` (letters, digits, `.`, `_`, `-`; it becomes a directory name under `profiles-data/live/`)
   - `port` — unique value between 9000 and 9099
   - `proto` — `nflow` or `sflow`

   The `conf/` directory is mounted read-only into both containers at `/etc/nfsen`, so the file is the container's `/etc/nfsen/sources.conf`. Both entrypoints validate it before doing anything: bad names, ports outside 9000-9099, duplicate names or ports and lines without `;` stop the container with `sources.conf:<line>: <reason>`. Blank lines, `#` comments, CRLF line endings and surrounding whitespace are tolerated. The UI's entrypoint derives `NFSEN_SOURCES` from the same file, so a source is added in one place.
4. Create `.env` from `.env.example` and set a password, then restrict the file — it holds the basic-auth hash:
   ```sh
   cp .env.example .env
   chmod 600 .env
   docker run --rm caddy:2 caddy hash-password --plaintext 'your-password' | sed 's/\$/\$\$/g'
   ```
   Paste the output into `AUTH_PASS_HASH` in `.env`. The `sed` step doubles the `$` signs — docker compose interpolates `$` in `.env`, so a raw bcrypt hash (starting with `$2a$`/`$2y$`) would be silently corrupted.
5. Start the stack:
   ```sh
   docker compose up -d
   ```
6. Browse to `https://localhost:8443` (accept the self-signed certificate warning) and log in with `AUTH_USER` and your password. The UI binds to `127.0.0.1` by default — from another machine, set `WEB_BIND_ADDR` first (see [Firewall](#firewall)).

On the first start the import daemon walks `profiles-data/live/` and builds the RRD databases, so the graphs fill in gradually; `docker compose logs -f nfsen` shows the progress.

7. Verify the stack (this is the repository's executable gate — there is no CI):

   ```sh
   ./scripts/smoke-test.sh                    # start if needed, then check
   ./scripts/smoke-test.sh --build            # rebuild the images first
   ./scripts/smoke-test.sh --password 'x'     # also log in through Caddy
   ./scripts/smoke-test.sh --down             # stop the stack afterwards
   ```

   It checks, in order: `docker compose` usable, `.env` present, `.env` mode `0600`, the hash is not the placeholder and is not shadowed by an exported variable (both abort before starting anything, because a broken hash stops `caddy` and takes the UI down), `docker-compose.yaml` parses, `conf/sources.conf` valid, the stack starts, `nfdump`/`nfsen`/`caddy` reach `healthy`, **the hash reaches Caddy as a bcrypt hash**, the UI port `:9000` is not published, the `Caddyfile` is actually visible inside the container (a stale bind mount otherwise hides it), the HTTP redirect names the published HTTPS port, no unreachable `alt-svc` is advertised, **both containers report the same `nfdump` version**, the app answers HTTP on `:9000`, and Caddy serves TLS and demands basic auth (`401` without credentials, `200` with `--password` — plus, then, the security headers and the absent `Server` header). Exit code is non-zero if anything fails, and every failure names the command that explains it.

## Configuration (.env)

| Variable          | Default     | Description |
|-------------------|-------------|-------------|
| `TZ`              | `UTC`       | Timezone for all containers (also passed to nfsen-ng as `NFCAPD_TZ`) |
| `HTTP_PORT`       | `8080`      | Host port for HTTP (redirects to HTTPS) |
| `HTTPS_PORT`      | `8443`      | Host port for HTTPS |
| `WEB_BIND_ADDR`   | `127.0.0.1` | Host address the UI binds to. Loopback by default — set `0.0.0.0` or a LAN address to expose it (see [Security](#security)) |
| `FLOW_BIND_ADDR`  | `0.0.0.0`   | Host address the flow collectors listen on. Open by default so routers can reach them; narrow it to the LAN address when possible |
| `UDP_PORT_RANGE`  | `9000-9099` | Host UDP range mapped to the collectors (container ports are always 9000-9099, as used in `sources.conf`) |
| `AUTH_USER`       | —           | Basic auth username (required) |
| `AUTH_PASS_HASH`  | —           | Basic auth password hash (required, see above) |
| `DOMAIN`          | `localhost` | Public domain for Let's Encrypt (see below) |
| `FLOW_RETENTION_DAYS` | `30`    | Flow data retention: `nfcapd` files older than this many days are deleted by `nfexpire` (see below). `0` disables expiry |
| `NFSEN_IMPORT_YEARS` | `3`      | Years of `nfcapd` history the import daemon walks on start-up |
| `NFSEN_TOPN_RETENTION_DAYS` | `31` | Days of per-interval top-N data kept in the state SQLite store (Overview tables); budget ~12 MB per source and day. `0` disables it |
| `NFSEN_PORTS`     | `80,443,22,53` | Service ports offered in the per-port views (comma-separated). Not the collector ports from `conf/sources.conf` |
| `NFSEN_LOG_LEVEL` | `info`      | `DEBUG`, `INFO`, `NOTICE`, `WARNING`, `ERR`, `CRIT`, `ALERT`, `EMERG` |
| `LOG_MAX_SIZE`    | `10m`       | Container stdout: max size per log file (docker `json-file` driver) |
| `LOG_MAX_FILES`   | `5`         | Container stdout: number of log files kept per container |
| `CADDY_CPUS`      | `1.0`       | CPU budget for the proxy in cores; fractions allowed. Every rejected request costs one bcrypt verification, so this bounds how hard a password-guessing flood can bite |
| `NFSEN_CPUS`      | `2.0`       | CPU budget for the UI/import process in cores. Raise it when the import falls behind on many sources |
| `NFDUMP_CPUS`     | `1.0`       | CPU budget for the collectors in cores |

Any other [nfsen-ng environment variable](https://mbolli.github.io/nfsen-ng/deployment/configuration.html) can be added to the `nfsen` service's `environment:` block in `docker-compose.yaml` (geolocation, MCP endpoint, VictoriaMetrics, alert e-mail, …).

### Flow data retention

Flow files (`nfcapd.*`, one per source every 5 minutes) grow without limit, so the `nfdump` container runs `nfexpire` — once at startup and then hourly — to delete files older than `FLOW_RETENTION_DAYS` (default 30) and clean up the empty day directories. Set `FLOW_RETENTION_DAYS=0` to keep everything.

```sh
# e.g. keep 90 days of flow data
FLOW_RETENTION_DAYS=90 docker compose up -d
```

Only the flow files are affected. The RRD databases live in `nfsen-state/` (see below) and are *not* pruned: shorten `FLOW_RETENTION_DAYS` below what the RRDs already cover and the older slots simply keep their last value.

### The state volume (`nfsen-state/`)

nfsen-ng keeps everything it derives from the capture files in `/var/lib/nfsen-ng`, mounted here as `./nfsen-state`:

- `rrd/` — the RRD databases behind the graphs,
- `state/` — `preferences.json`, the alert rule state, and `nfsen-ng.sqlite` (saved filters, alert history, per-interval top-N data).

It survives `docker compose up -d --build`, so upgrading the UI does not re-import years of history. Back it up (or at least `state/preferences.json` and `state/nfsen-ng.sqlite`) before removing the directory: deleting it forces a full re-import. RRD files are fixed-size (~5 MB per source), the SQLite store grows with `NFSEN_TOPN_RETENTION_DAYS`.

### Operational logs

- **Caddy access log** — JSON, at `caddy-data/access.log` (host) = `/data/access.log` (container), rotated at 10 MB with 5 rotations kept (7 days max). One JSON object per request with `remote_ip`, `host`, `uri`, `status` — this is what the fail2ban recipe below matches.
- **Container stdout** (`docker compose logs`) — nfsen-ng logs to stdout (level: `NFSEN_LOG_LEVEL`), the collectors log each started collector; rotated by Docker's `json-file` driver: `LOG_MAX_SIZE` per file, `LOG_MAX_FILES` files per container.
- **App log file** — Swoole writes `/tmp/swoole.log` inside the nfsen container; it is disposable, `docker compose logs` is the canonical place.

### Alerting

Logs nobody reads are not monitoring. `scripts/watch-alerts.sh` is a read-only
checker for the failures that otherwise stay quiet until someone notices missing
data — it starts nothing and changes nothing:

```sh
./scripts/watch-alerts.sh --dry-run     # show findings, send nothing
./scripts/watch-alerts.sh               # send, but only when the finding changes
ALERT_URL=https://ntfy.sh/your-topic ./scripts/watch-alerts.sh
```

What it checks: containers running/**healthy**, a capture file written in the last
`FRESH_MIN` minutes (15) — a silent router or firewall change looks exactly like
“nothing interesting happened” in the UI — free disk above `DISK_MIN_FREE` (10%,
because a full disk truncates capture files), basic-auth failures above
`AUTH_MAX_FAILURES` (20) within `AUTH_WINDOW_MIN` (10) minutes, and whether the
running Caddy can even see the Caddyfile that is in the repo (a stale bind mount
otherwise serves a config nobody is editing).

`ALERT_URL` gets a plain-text `POST` (ntfy, a generic webhook, a Slack workflow
URL — anything that accepts a body). Without it the script behaves like a plain
checker: findings on stdout, exit code 1, so cron mails them. It only notifies when
the finding *changes*, so a standing problem does not page every five minutes.

Run it from cron (Linux):

```cron
*/5 * * * * cd /path/to/nfsen-ng-docker && ALERT_URL=https://ntfy.sh/topic ./scripts/watch-alerts.sh >/dev/null
```

or from launchd (macOS) with a plist whose `ProgramArguments` are `/bin/bash -lc`
plus the same line. On macOS this is the **only** detector for failed logins: the
fail2ban jail below bans via `iptables` and therefore needs a Linux host.

### Let's Encrypt (public domain)

1. Point a DNS record at this host.
2. Set `DOMAIN=nfsen.example.com` in `.env`.
3. Remove the `tls internal` line from `caddy/Caddyfile`.
4. `docker compose up -d`

Caddy obtains and renews the Let's Encrypt certificate automatically.

### Changing ports

Ports are configured in `.env` — no need to edit `docker-compose.yaml`. `HTTPS_PORT` is passed to Caddy, so the HTTP→HTTPS redirect always names the port that is actually published.

The defaults are `8080`/`8443` rather than `80`/`443` because ports below 1024 can only be published by a **rootful** daemon (Docker Desktop, colima). With a rootless runtime (e.g. kiri) `docker compose up` fails with `Engine ports not published; ... Permission denied (os error 13)`. On a rootful daemon you can switch back to `80`/`443` in `.env`.

### Reaching the UI from other machines (LAN)

Three values change together. Changing only the first is the usual way to end up with a certificate warning and then a connection that fails outright:

| Variable | Value | Why |
|---|---|---|
| `WEB_BIND_ADDR` | `10.0.0.171` | otherwise Docker publishes the port on loopback only |
| `DOMAIN` | `10.0.0.171` | Caddy issues the certificate for *this* name; browsing an address while `DOMAIN=localhost` is a name mismatch |
| `CADDY_DEFAULT_SNI` | `10.0.0.171` | **only for a bare IP**: browsers send no SNI for IP literals, so Caddy cannot pick a certificate and the handshake dies with `tlsv1 alert internal error` |

```sh
docker compose up -d --force-recreate caddy
```

**Better: use a name instead of the IP.** `DOMAIN=nfsen.lan` with a DNS record (or an `/etc/hosts` line on the clients) pointing at `10.0.0.171` needs no SNI workaround, matches the certificate without warnings once the root CA is trusted, and lets HSTS do something — browsers ignore HSTS for IP literals, so on a bare IP that header is silently dropped.

Trusting the certificate (`tls internal`): copy `caddy-data/caddy/pki/authorities/local/root.crt` to the clients — on Linux into `/usr/local/share/ca-certificates/` followed by `update-ca-certificates`, on macOS into Keychain Access with "Always trust". Trust the **root**: the leaf is valid for 12 hours and rotates (see `openssl x509 -noout -dates` against the site), so pinning the leaf is a trap.

`./scripts/smoke-test.sh` checks the combination above: with `DOMAIN` set to an IPv4 literal and no matching `CADDY_DEFAULT_SNI`, it fails with that hint instead of a TLS error.

Remember that the UI is now visible to the whole LAN, and one shared password is its only protection — see [`docs/adr/0001-auth-and-collector-trust.md`](docs/adr/0001-auth-and-collector-trust.md) for the allowlist snippet and the alternatives.

## Upgrading from the v0.4 setup

This repository used to build nfsen-ng **v0.4.0** on Apache + php-fpm. It now runs **1.0.0-beta.7**, where the whole UI — pages, static assets, SSE, import daemon — is one OpenSwoole process on port 9000. What that means in practice:

| | v0.4 setup | now |
|---|---|---|
| UI runtime | Apache + php-fpm (Alpine) | OpenSwoole/php-via inside the upstream image (Debian, PHP 8.4) |
| Internal port | 80 (FastCGI on 9000) | 9000, app serves everything |
| Config | `settings.php` generated from a template | `NFSEN_*` env vars; `conf/sources.conf` still the source of truth |
| UI state | RRD inside the container, rebuilt on recreate | `./nfsen-state` (RRD + SQLite), persistent |
| `nfdump` | distro packages, two different versions | 1.7.10 compiled in both images |
| Apache logs | `logs/nfsen/*.log` + `LOG_RETENTION_DAYS` | stdout only (`docker compose logs`) |

The capture tree is compatible: both versions expect `<profiles-data>/live/<source>/YYYY/MM/DD/nfcapd.*`, which is what `nfcapd -S 1` writes — no reorganising needed.

Removed along with Apache: `nfsen-ng/httpd.conf`, `php-fpm.conf`, `php.ini`, `healthcheck.sh`, `settings.php`, the `logs/nfsen/` mount and `LOG_RETENTION_DAYS`. The host's `logs/` directory is no longer used — delete it (`rm -rf logs`) if you do not want the old Apache logs around.

Because the app changed completely, the first start imports history into a **new** RRD/SQLite store — allow it to run (watch `docker compose logs -f nfsen`). Nothing is lost: the capture files are the source of truth.

### Bumping a pinned dependency

Base images are pinned by digest, and the nfdump archive by sha256; the nfsen-ng tag is asserted against a pinned commit. Nothing here floats:

```sh
# base image digest (pick the tag you want, then take its index digest)
docker pull php:8.4-cli
docker image inspect php:8.4-cli --format '{{index .RepoDigests 0}}'

# nfdump archive (only when NFDUMP_VERSION changes)
docker run --rm caddy:2-alpine sh -c \
  'wget -qO /tmp/n.zip https://github.com/phaag/nfdump/archive/refs/tags/v1.7.10.zip && sha256sum /tmp/n.zip'

# commit behind an nfsen-ng tag
curl -s https://api.github.com/repos/mbolli/nfsen-ng/git/refs/tags/v1.0.0-beta.7 | grep -m1 '"sha"'
```

Change the value **and** its comment together, then `docker compose build`. The CI build is what catches a re-pointed tag or a changed checksum; `scripts/smoke-test.sh` is what catches a working build that no longer serves.

## Firewall

Two different things listen on the host, and they need different treatment:

| What | Default binding | Who needs it |
|---|---|---|
| UI (TCP 80/443) | `127.0.0.1` (`WEB_BIND_ADDR`) | you, from this machine |
| Collectors (UDP 9000-9099) | `0.0.0.0` (`FLOW_BIND_ADDR`) | the routers sending flows |

**The UI is not reachable from the LAN out of the box.** To use it from another machine, set the address explicitly — and restrict it to the network you trust:

```sh
# .env
WEB_BIND_ADDR=192.168.10.5     # a host address, not 0.0.0.0, if you can
```

For the collectors, narrow `FLOW_BIND_ADDR` to the address the routers talk to:

```sh
# .env
FLOW_BIND_ADDR=192.168.10.5
```

`FLOW_BIND_ADDR=0.0.0.0` with `UDP_PORT_RANGE` is a wildcard listener on every interface; if you keep it, firewall the range.

### Docker publishes ports, `ufw`/`firewalld` `INPUT` rules do not apply

Docker inserts its own DNAT rules into `nat/PREROUTING`, so published ports are forwarded and evaluated in `FORWARD`, not `INPUT`. `ufw allow 9000/udp` therefore does **not** do what it looks like for published container ports, and neither does `ufw deny`.

- With **`ufw`**: allow forwarding rules in the `DOCKER-USER` chain. Docker evaluates that chain before its own forwarding rules, and it is the supported hook:
  ```sh
  # allow flow data only from the two router addresses
  ufw route allow proto udp from 192.168.10.1 to any port 9000
  ufw route allow proto udp from 192.168.10.2 to any port 9001
  ```
  (`ufw route allow` writes into `DOCKER-USER`.) Alternatively, bind to an address/interface instead of relying on the host firewall: `FLOW_BIND_ADDR` / `WEB_BIND_ADDR`.
- With **raw iptables/nftables**: add explicit rules to `DOCKER-USER`, e.g.
  ```sh
  iptables -I DOCKER-USER -p udp --dport 9000:9099 -s 192.168.10.0/24 -j RETURN
  iptables -A DOCKER-USER -p udp --dport 9000:9099 -j DROP
  ```

## Security

What this setup does and does not protect:

- **The collectors do not authenticate senders.** Anyone who can reach a collector's UDP port can inject flows (visible in the UI, and stored until `FLOW_RETENTION_DAYS`). Limit reachability with `FLOW_BIND_ADDR` and the `DOCKER-USER` rules above; prefer exporting over a management network. `firewall/nftables-nfsen.nft` is the nftables version of the same rule (it has to hook `forward`, not `input`, so it sees DNAT'd traffic).
- **One shared credential for the dashboard — no roles, no MFA, no revocation.** The options (status quo, `forward_auth` + an IdP, network identity, an IP allowlist) are compared in [`docs/adr/0001-auth-and-collector-trust.md`](docs/adr/0001-auth-and-collector-trust.md), with the exact Caddyfile change for the cheap one. This is the largest remaining gap in the stack and it is a product decision, not a bug.
- **Basic auth is the only access control for the UI.** The `.env` file holds the password hash: `chmod 600 .env`. Basic auth credentials are sent on every request — TLS is what keeps them off the wire.
- **`tls internal`** (the default) presents a self-signed certificate: encrypted, but not vouched for by a CA. Browsers warn, and users learn to click through warnings. For anything long-lived, use a real certificate (`DOMAIN` + Let's Encrypt, see above).
- Containers run with `no-new-privileges`, `cap_drop: ALL` (only Caddy re-adds `NET_BIND_SERVICE`, to bind `:80`/`:443` inside its container), read-only root filesystem for the collector, and CPU/RAM/PID limits.
- **The UI process runs as uid 1000** — the same user as the collector, which owns the capture files, so reading them needs no capability; `cap_drop: ALL` leaves it with none at all. Its view of `profiles-data` is mounted **read-only**: the UI reads capture files and never writes them (no `nfexpire`, no `unlink`/`rmdir` on that path — checked against the app source), so a compromised UI cannot tamper with or delete the flow records the analysis rests on. Upgrading an existing install on Linux: `chown -R 1000:1000 nfsen-state` once, otherwise the app cannot write its SQLite store and RRD files.
- The UI's port 9000 is not published: only Caddy reaches it, over the compose network. `sources.conf` is validated by both entrypoints before use — a device name becomes a directory name and an nfsen-ng source name.
- **The compose network has no egress** (`nfsen-net` is `internal: true`). Nothing here needs the internet at runtime, so a compromised UI has nowhere to send captured flow data. Published ports still work — the daemon DNATs them straight to the container. Features that call out (geolocation tiles, alert e-mail, an MCP dependency) need a second, non-internal network for the `nfsen` service.
- **Response headers:** `X-Content-Type-Options`, `X-Frame-Options: DENY`, `Referrer-Policy`, `Cross-Origin-Opener-Policy`/`-Resource-Policy`, `Permissions-Policy`, `X-Robots-Tag`, an enforced `Content-Security-Policy` (`object-src 'none'; base-uri 'self'; form-action 'self'`), the full policy in report-only mode, and `Strict-Transport-Security` for real hostnames only (never `localhost`, where it would pin a self-signed certificate for a year). Caddy's `Server` header is stripped. Caveat: Caddy applies these from a deferred handler, so **`401` responses — the ones an unauthenticated attacker sees — carry none of them and still say `Server: Caddy`**; do not treat the headers as protection for rejected requests.
- **Not enabled by default:** nfsen-ng's read-only MCP endpoint (`NFSEN_MCP_HTTP=true` exposes `/_mcp` on port 9000). Treat access to it as equivalent to access to the dashboard.

### Content-Security-Policy

The UI renders inline `<script type="module">` blocks and an importmap, so `'unsafe-inline'` for scripts cannot be avoided without changes upstream. What the full policy still buys once enforced: no third-party script origins, and no exfiltration to another host (`connect-src`/`img-src`/`form-action`) — which is what a stored-XSS payload against flow data would need.

It ships as `Content-Security-Policy-Report-Only`, so nothing breaks and violations only appear in the browser console. To enforce it:

1. open the UI, walk the pages you actually use (Overview, Flows, Alerts, Health, a filter drawer, a live graph) with DevTools open;
2. look for `Refused to …` / `Content Security Policy` messages;
3. when the console is clean, rename the header in `caddy/Caddyfile` from `Content-Security-Policy-Report-Only` to `Content-Security-Policy`, then `docker compose up -d --force-recreate caddy`.

If you enable nfsen-ng's geolocation, map tiles come from another origin — add that origin to `img-src` before enforcing, or keep the policy report-only.

### fail2ban for the UI

Caddy writes a JSON access log to `caddy-data/access.log`. Failed basic-auth attempts appear as `401`. The filter and jail ship in this repo — copy them where fail2ban reads them, set `logpath`, done:

```sh
sudo cp fail2ban/filter.d/caddy-401.conf /etc/fail2ban/filter.d/
sudo cp fail2ban/jail.d/caddy.local     /etc/fail2ban/jail.d/
# edit logpath in the jail: absolute path to this repo's caddy-data/access.log
```

Two things about that filter are easy to get wrong, and both were verified against a real log here — an earlier version matched **0 of 97** recorded 401s:

- `remote_ip` is inside `request`, `status` is top-level and comes after `request` closes, so `<HOST>…[^}]*…"status":401` can never match. `.*` is required.
- fail2ban matches the `failregex` against the remainder of the line **after** the date match. With a `datepattern` anchored at the start of the JSON, an anchored `failregex` sees a line starting mid-object and matches nothing. The shipped filter therefore keeps `datepattern` and drops `^` from the regexes.

The jail bans in `DOCKER-USER`, because traffic to published container ports arrives through Docker's DNAT — a plain `iptables` ban in `INPUT` never sees it (same reasoning as the firewall section above).

#### How to test it

Always run this before enabling the jail — it needs no running fail2ban, only its Python module:

```sh
fail2ban-regex caddy-data/access.log fail2ban/filter.d/caddy-401.conf
```

What a working filter looks like (`97` is this repo's sample log; yours will differ):

```
Failregex: 97 total
|-  #) [# of hits] regular expression
|   1) [97] "remote_ip":"<HOST>".*"status":401
Date template hits: [1077] ^\{"level":"info","ts":(?P<time>\d+)
Lines: 1089 lines, 0 ignored, 97 matched, 992 missed
```

`0 matched` means the regex, not fail2ban, is wrong — `--print-all-missed` shows the lines it skipped. Also check for false positives, which is the half that actually bites in production:

```sh
grep '"status":200' caddy-data/access.log > /tmp/only200.log
fail2ban-regex /tmp/only200.log fail2ban/filter.d/caddy-401.conf   # must report 0 matched
```

On a host without fail2ban (macOS, Windows) run the same check in a throwaway container — no jail, no iptables, just the regex engine:

```sh
docker run --rm \
  -v "$PWD/caddy-data:/logs:ro" \
  -v "$PWD/fail2ban/filter.d:/filters:ro" \
  alpine sh -c 'apk add --no-cache -q fail2ban && fail2ban-regex /logs/access.log /filters/caddy-401.conf'
```

Note for macOS/Windows hosts: that container test validates the **filter only**. The jail above bans with `iptables`, so it needs a Linux host (and root). On Docker Desktop/Kiri the ban would have to be a `pf` rule or a rate limit in front of Caddy instead — until then the filter is useful only as a detector.

## nfdump version

nfdump's file format is stable within a minor series but not across it, and a writer/reader mismatch shows up as an empty UI rather than an error. Here that cannot happen:

- the **collector** compiles `ARG NFDUMP_VERSION` (default 1.7.10) from source in a build stage and asserts `nfdump -V` plus the presence of `nfcapd`, `sfcapd`, `nfexpire` and `nfdump`;
- the **UI** image compiles the same 1.7.10 (a shared multi-stage build) — 1.7.9 was the release that fixed remotely triggerable crashes in the collectors and file parsers, which is why both sides are newer than any distro package.

```sh
docker compose exec nfdump nfdump -V | head -1
docker compose exec nfsen  nfdump -V | head -1   # same version
```

## Adding / removing sources

Edit `conf/sources.conf`, check it, then restart the stack:

```sh
./scripts/validate-sources.sh conf/sources.conf   # same validator the containers run
docker compose restart
```

The validator prints the normalized list and exits non-zero with `sources.conf:<line>: <reason>` on anything it would refuse at start-up (bad name, port outside 9000-9099, duplicate name or port, missing field).

`docker compose restart` re-runs both entrypoints: the collector starts one `nfcapd`/`sfcapd` per line, the UI re-derives `NFSEN_SOURCES` from the same file.

## Troubleshooting

- **Build fails with `no match for platform in manifest` / `not found`** — the image you are pulling has no build for your CPU architecture. Upstream's ghcr.io images are `linux/amd64` only, which is why the UI is built locally here; if you reintroduce a prebuilt image, pin `platform: linux/amd64` and accept emulation, or build from source.
- **Collectors fail to start with "Permission denied"** — `profiles-data` must be writable by uid 1000: `docker run --rm -v "$PWD/profiles-data:/data" alpine chown -R 1000:1000 /data`
- **UI fails with "`/var/lib/nfsen-ng/...` is not writable"** — remove `nfsen-state/` or fix its ownership; the app writes the RRD databases and the SQLite store there.
- **`sources.conf:<line>: ...` in the logs** — the container refuses to start on an invalid `sources.conf`; the message names the line and the reason.
- **`Error: /etc/nfsen/sources.conf is not a regular file` / `no sources defined`** — `conf/sources.conf` is missing or empty. `conf/` is mounted as a *directory*, not as a single file: a file bind mount is silently unreliable on some daemons (colima/lima can hand the container the host file as an empty directory), and a file mount under the collector's `tmpfs`-backed `/tmp` is hidden entirely.
- **nfsen shows no data** — check that flow files are being written: `docker compose exec nfdump sh -c 'ls -R /data/live/<device> | head'`. `nfcapd` runs with `-S 1`, which nfdump expands to `YYYY/MM/DD`, so files land in `<device>/<year>/<month>/<day>/nfcapd.<YYYYMMDDHHMM>` and a new one appears every 5 minutes per source. If the tree is empty, no flows are arriving — check the firewall and the device's export configuration.
- **Health page reports errors** — it is diagnostic: unreadable capture directories, a stale newest file (collector down), or a timezone mismatch between `NFCAPD_TZ` and `TZ`. Each row names the source and the problem.
- **`Error: no capture directory for: <source>`** — nfsen-ng refuses to start when `<profiles-data>/live/<source>/` is missing, so the wrapper waits up to 30 s for the collector to create it and then says so instead of letting the app throw. Check `docker compose ps nfdump` and `docker compose logs nfdump`; on a plain `docker compose restart` the two services are not ordered, which is what the wait is for.
- **UI is `unhealthy` while `docker compose logs nfsen` looks fine** — the healthcheck fetches `http://127.0.0.1:9000/favicon.svg` inside the container: it proves the HTTP stack answers, but a page that errors only while running an `nfdump` query still looks healthy from here. Run `docker compose exec nfsen php -v` to confirm the container is alive, and check the UI itself for page-level errors.
- **Graphs stay empty after a fresh start** — the initial import is still running (`NFSEN_IMPORT_YEARS`, default 3, walks the whole tree) or `NFSEN_TOPN_RETENTION_DAYS=0` disabled the Overview tables. Watch `docker compose logs -f nfsen`.
- **Debug the UI without Caddy** — temporarily add `ports: ["127.0.0.1:81:9000"]` to the `nfsen` service in `docker-compose.yaml`, then browse to `http://localhost:81`
- **`Permission denied (os error 13)` when starting `caddy`** — the daemon is rootless and cannot publish a privileged host port. Keep `HTTP_PORT`/`HTTPS_PORT` above 1024 (the defaults `8080`/`8443` already do), or switch to a rootful daemon.
- **`docker compose up` says "address already in use"** — `WEB_BIND_ADDR`/`HTTP_PORT`/`HTTPS_PORT` collide with something on the host (a local web server on `127.0.0.1:80` is common). Set `HTTP_PORT`/`HTTPS_PORT` in `.env`, or `WEB_BIND_ADDR` to another address.
- **Reset the password** — regenerate the hash, update `AUTH_PASS_HASH` in `.env`, then `docker compose up -d caddy`
- **`caddy` exits with `base64-decoding password: illegal base64 data at input byte N`** — the hash did not arrive intact; Caddy refuses to start (fail-closed, but the message names neither the file nor the variable). Two causes, both seen here:
  1. the `$$` escaping was lost (compose interpolates `$` in `.env`, so a bcrypt hash must be written `$$2a$$14$$…`); or
  2. **`AUTH_PASS_HASH` is already exported in your shell** — compose gives the environment precedence over `.env`, so a stale or mangled value in the shell wins silently. Anything that *sources* `.env` instead of parsing it expands `$$` to a PID, producing exactly this failure.

  Check what actually reaches the container before guessing:
  ```sh
  docker compose config --format json | grep AUTH_PASS_HASH   # must start with $$2a$14$ (re-escaped for display)
  printenv AUTH_PASS_HASH                                     # should print nothing
  env -u AUTH_PASS_HASH docker compose up -d caddy            # start with the value from .env instead
  ```
- **A change to `Caddyfile` (or `conf/sources.conf`) has no effect, and `/etc/caddy` looks empty inside the container** — the bind mount of a long-running container can go stale when the host file is replaced (editors and `git checkout` write a new inode through rename). The container keeps serving the config it loaded at start, and `caddy reload` cannot even read the file. Recreate rather than reload, and check:
  ```sh
  docker compose exec caddy ls -l /etc/caddy        # empty output = stale mount
  docker compose up -d --force-recreate caddy
  ```

## Tested with

- Arista EOS 4.23.3M (Jan 2021)
- Ubiquiti EdgeRouter™ X

## An issue ?

1. clone
2. correct
3. share
