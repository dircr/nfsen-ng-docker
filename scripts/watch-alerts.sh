#!/usr/bin/env bash
# Watch the running stack and shout when something is wrong.
#
#   ./scripts/watch-alerts.sh                 # check, send only on change
#   ./scripts/watch-alerts.sh --dry-run       # print findings, send nothing
#   ./scripts/watch-alerts.sh --force         # send even when everything is fine
#
# Read-only: it starts nothing and changes nothing. The only state it keeps is a
# fingerprint of the last alert, so a stable problem does not re-notify every
# run and a new problem is not swallowed.
#
# Exit codes: 0 = healthy (or alert delivered), 1 = problems found but no
# ALERT_URL configured, 2 = usage error.
#
# Why this exists: fail2ban handles brute force on Linux, but it says nothing
# about a collector that stopped receiving flows, a container in a crash loop, a
# full disk (which silently truncates capture files), 401 bursts on a host
# without fail2ban, or a bind mount that went stale (the running container then
# serves a config that is no longer in the repo).
set -uo pipefail

cd "$(dirname "$0")/.." || exit 2

DRY_RUN=0
FORCE=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1 ;;
        --force) FORCE=1 ;;
        -h|--help) sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Error: unknown argument '$1'" >&2; exit 2 ;;
    esac
    shift
done

ALERT_URL="${ALERT_URL:-}"
FRESH_MIN="${FRESH_MIN:-15}"          # a capture file must be touched this often
DISK_MIN_FREE="${DISK_MIN_FREE:-10}"  # percent
AUTH_WINDOW_MIN="${AUTH_WINDOW_MIN:-10}"
AUTH_MAX_FAILURES="${AUTH_MAX_FAILURES:-20}"
STATE_FILE="${STATE_FILE:-${XDG_CACHE_HOME:-$HOME/.cache}/nfsen-ng-docker.alerts}"

PROBLEMS=()

problem() { PROBLEMS+=("$1"); }

# ── 1. containers ────────────────────────────────────────────────────────────
if ! command -v docker >/dev/null 2>&1; then
    problem "docker CLI not in PATH — cannot check the stack"
else
    for service in nfdump nfsen caddy; do
        id="$(docker compose ps -q "$service" 2>/dev/null)"
        if [ -z "$id" ]; then
            problem "$service: container is not running"
            continue
        fi
        state="$(docker inspect -f \
            '{{.State.Status}}{{if .State.Health}}/{{.State.Health.Status}}{{end}}' \
            "$id" 2>/dev/null)"
        case "$state" in
            running/healthy|running) ;;
            *) problem "$service: $state" ;;
        esac
    done
fi

# ── 2. the collector is still writing files ──────────────────────────────────
# nfcapd rotates every 5 minutes, so a 15 minute silence means no flows arrive
# (router down, firewall change, wrong port) — the UI shows nothing new and no
# error anywhere.
profiles_dir="${NFSEN_NFDUMP_PROFILES_DIR:-profiles-data/live}"
if [ -d "$profiles_dir" ]; then
    if ! find "$profiles_dir" -type f -name 'nfcapd.*' -mmin "-$FRESH_MIN" 2>/dev/null | head -1 | grep -q .; then
        problem "no capture file written in the last ${FRESH_MIN} min under $profiles_dir"
    fi
else
    problem "$profiles_dir does not exist"
fi

# ── 3. disk space (a full disk silently truncates capture files) ────────────
free_pct="$(df -Pk . 2>/dev/null | awk 'NR==2 { printf "%d", int($4 * 100 / $2) }')"
if [ -n "$free_pct" ] && [ "$free_pct" -lt "$DISK_MIN_FREE" ]; then
    problem "only ${free_pct}% disk free"
fi

# ── 4. basic-auth failures in the recent log tail ───────────────────────────
log_path="caddy-data/access.log"
if [ -r "$log_path" ]; then
    since="$(( $(date +%s) - AUTH_WINDOW_MIN * 60 ))"
    failures="$(tail -n 5000 "$log_path" 2>/dev/null | awk -v since="$since" '
        {
            if (match($0, /"ts":[0-9.]+/)) {
                ts = substr($0, RSTART + 5, RLENGTH - 5) + 0;
                if (ts >= since && index($0, "\"status\":401")) count++;
            }
        }
        END { printf "%d", count + 0 }
    ')"
    if [ "${failures:-0}" -gt "$AUTH_MAX_FAILURES" ]; then
        problem "${failures} failed logins in ${AUTH_WINDOW_MIN} min (threshold ${AUTH_MAX_FAILURES}) — see the fail2ban filter in README.md"
    fi
else
    problem "$log_path is not readable — access log missing or permissions changed"
fi

# ── 5. the container sees the Caddyfile that is in the repo ─────────────────
# A long-running container can keep a stale view of a bind mount; it then keeps
# serving a config that no longer matches the file anyone is editing.
if command -v docker >/dev/null 2>&1 && [ -f caddy/Caddyfile ]; then
    host_sum="$(sha256sum caddy/Caddyfile 2>/dev/null | cut -d' ' -f1)"
    [ -z "$host_sum" ] && host_sum="$(shasum -a 256 caddy/Caddyfile 2>/dev/null | cut -d' ' -f1)"
    ctr_sum="$(docker compose exec -T caddy sha256sum /etc/caddy/Caddyfile 2>/dev/null | cut -d' ' -f1)"
    if [ -z "$ctr_sum" ]; then
        problem "caddy cannot read /etc/caddy/Caddyfile (stale mount?) — docker compose up -d --force-recreate caddy"
    elif [ -n "$host_sum" ] && [ "$host_sum" != "$ctr_sum" ]; then
        problem "caddy serves a Caddyfile that differs from the repo — docker compose up -d --force-recreate caddy"
    fi
fi

# ── report ───────────────────────────────────────────────────────────────────
host="$(uname -n)"
if [ "${#PROBLEMS[@]}" -eq 0 ]; then
    message="nfsen-ng-docker on $host: all checks passed"
else
    message="nfsen-ng-docker on $host: ${#PROBLEMS[@]} problem(s)"
    for p in "${PROBLEMS[@]}"; do
        message="$message
- $p"
    done
fi

# Fingerprint: notify on change only (a stable problem, or health, stays quiet).
fingerprint="$(printf '%s\n' "$message" | sha256sum 2>/dev/null | cut -d' ' -f1)"
[ -z "$fingerprint" ] && fingerprint="$(printf '%s\n' "$message" | shasum -a 256 | cut -d' ' -f1)"
last=""
[ -r "$STATE_FILE" ] && last="$(cat "$STATE_FILE" 2>/dev/null)"

if [ "$DRY_RUN" = 1 ]; then
    printf '%s\n\n[%s]\n' "$message" \
        "$( [ "${#PROBLEMS[@]}" -eq 0 ] && echo "would stay quiet" || echo "would notify (if changed since last run)" )"
    exit 0
fi

if [ "$FORCE" = 0 ] && [ "$fingerprint" = "$last" ]; then
    exit 0
fi

if [ -n "$ALERT_URL" ]; then
    curl -fsS -m 15 -X POST -H 'Content-Type: text/plain; charset=utf-8' \
        --data-binary "$message" "$ALERT_URL" >/dev/null 2>&1
    rc=$?
    # 0 = acknowledged. 52 = the endpoint closed the connection without an HTTP
    # response; the body was delivered, and plenty of webhook receivers behave
    # that way. Anything else means the alert was rejected or never sent.
    case "$rc" in
        0) delivered=1 ;;
        52) delivered=1; echo 'Warning: endpoint sent no response, alert body was delivered' >&2 ;;
        *) delivered=0 ;;
    esac
    if [ "$delivered" = 1 ]; then
        mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null
        printf '%s\n' "$fingerprint" > "$STATE_FILE"
        exit 0
    fi
    echo "Error: could not POST to ALERT_URL (curl exit $rc)" >&2
    echo "$message" >&2
    exit 1
fi

# No webhook configured: act like a plain checker (cron mails stdout).
echo "$message"
mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null
printf '%s\n' "$fingerprint" > "$STATE_FILE"
[ "${#PROBLEMS[@]}" -eq 0 ] && exit 0
exit 1
