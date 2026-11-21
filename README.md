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

   It checks, in order: `docker compose` usable, `.env` present, `docker-compose.yaml` parses, `conf/sources.conf` valid, the stack starts, `nfdump`/`nfsen`/`caddy` reach `healthy`, **both containers report the same `nfdump` version**, the app answers HTTP on `:9000`, and Caddy serves TLS and demands basic auth (`401` without credentials, `200` with `--password`). Exit code is non-zero if anything fails, and every failure names the command that explains it.

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

### Let's Encrypt (public domain)

1. Point a DNS record at this host.
2. Set `DOMAIN=nfsen.example.com` in `.env`.
3. Remove the `tls internal` line from `caddy/Caddyfile`.
4. `docker compose up -d`

Caddy obtains and renews the Let's Encrypt certificate automatically.

### Changing ports

Ports are configured in `.env` — no need to edit `docker-compose.yaml`. `HTTPS_PORT` is passed to Caddy, so the HTTP→HTTPS redirect always names the port that is actually published.

The defaults are `8080`/`8443` rather than `80`/`443` because ports below 1024 can only be published by a **rootful** daemon (Docker Desktop, colima). With a rootless runtime (e.g. kiri) `docker compose up` fails with `Engine ports not published; ... Permission denied (os error 13)`. On a rootful daemon you can switch back to `80`/`443` in `.env`.

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

- **The collectors do not authenticate senders.** Anyone who can reach a collector's UDP port can inject flows (visible in the UI, and stored until `FLOW_RETENTION_DAYS`). Limit reachability with `FLOW_BIND_ADDR` and the `DOCKER-USER` rules above; prefer exporting over a management network.
- **Basic auth is the only access control for the UI.** The `.env` file holds the password hash: `chmod 600 .env`. Basic auth credentials are sent on every request — TLS is what keeps them off the wire.
- **`tls internal`** (the default) presents a self-signed certificate: encrypted, but not vouched for by a CA. Browsers warn, and users learn to click through warnings. For anything long-lived, use a real certificate (`DOMAIN` + Let's Encrypt, see above).
- Containers run with `no-new-privileges`, `cap_drop: ALL` (plus the minimum each one needs — Caddy `NET_BIND_SERVICE`, the UI `DAC_OVERRIDE` to read capture files owned by the collector's uid), read-only root filesystem for the collector, and CPU/RAM/PID limits.
- **The UI process runs as root inside its container** (the upstream `php:8.4-cli` base has no `USER`), because OpenSwoole binds port 9000 and the import daemon spawns `nfdump`. It is contained by `no-new-privileges`, `cap_drop: ALL` with only `DAC_OVERRIDE`, a 1 GiB memory / 2 CPU / 256 PID budget, and no published ports — but it is not an unprivileged process, unlike the collector.
- The UI's port 9000 is not published: only Caddy reaches it, over the compose network. `sources.conf` is validated by both entrypoints before use — a device name becomes a directory name and an nfsen-ng source name.
- **Not enabled by default:** nfsen-ng's read-only MCP endpoint (`NFSEN_MCP_HTTP=true` exposes `/_mcp` on port 9000). Treat access to it as equivalent to access to the dashboard.

### fail2ban for the UI

Caddy writes a JSON access log to `caddy-data/access.log`. Failed basic-auth attempts appear as `401`. Example filter (`/etc/fail2ban/filter.d/caddy-401.conf`) — note that `remote_ip` and `status` can appear in either order in the JSON object:

```ini
[Definition]
failregex = ^\{"level":"info".*"remote_ip":"<HOST>"[^}]*"status":401
            ^\{"level":"info".*"status":401[^}]*"remote_ip":"<HOST>"
datepattern = ^\{"level":"info","ts":(?P<time>\d+\.?\d*)
```

Jail (`/etc/fail2ban/jail.d/caddy.local`). Ban in `DOCKER-USER`: traffic arrives through Docker's DNAT (it lands on the `docker-proxy`/container network), so a plain `iptables` ban in `INPUT` does not stop it:

```ini
[caddy-401]
enabled  = true
port     = http,https
filter   = caddy-401
logpath  = /path/to/nfsen-ng-docker/caddy-data/access.log
maxretry = 5
findtime = 10m
bantime  = 1h
action   = iptables-allports[chain=DOCKER-USER, protocol=all, name=caddy-401]
```

Verify before enabling — matches on 401, none on 200:

```sh
fail2ban-regex /path/to/nfsen-ng-docker/caddy-data/access.log /etc/fail2ban/filter.d/caddy-401.conf
```

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

## Tested with

- Arista EOS 4.23.3M (Jan 2021)
- Ubiquiti EdgeRouter™ X

## An issue ?

1. clone
2. correct
3. share
