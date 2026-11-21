#!/usr/bin/env bash
# Smoke test for this stack: the checks a human would otherwise do by hand
# after every image or config change.
#
#   ./scripts/smoke-test.sh                 # test the running stack (starts it)
#   ./scripts/smoke-test.sh --build         # rebuild the images first
#   ./scripts/smoke-test.sh --down          # stop the stack afterwards
#   ./scripts/smoke-test.sh --password 'x'  # also verify a login through Caddy
#
# Exit code 0 only when every check passed. Without --password the Caddy check
# asserts a 401: that still proves TLS, routing and basic auth are wired, and
# needs no secret on the command line.
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1

BUILD=0
DOWN=0
PASSWORD=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --build) BUILD=1 ;;
        --down) DOWN=1 ;;
        --password)
            shift
            PASSWORD="${1:-}"
            [ -n "$PASSWORD" ] || { echo "Error: --password needs a value" >&2; exit 2; }
            ;;
        -h|--help)
            sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Error: unknown argument '$1' (see --help)" >&2
            exit 2
            ;;
    esac
    shift
done

FAILED=0
RESULTS=()

record() { # record <status> <name> [detail]
    RESULTS+=("$(printf '%-6s %-46s %s' "$1" "$2" "${3:-}")")
    [ "$1" = "FAIL" ] && FAILED=1
}

# Values come from .env (compose reads it too); parsed, not sourced, so nothing
# in that file can execute.
env_value() { # env_value <key> <default>
    local value=""
    [ -f .env ] && value="$(grep -E "^[[:space:]]*$1=" .env | tail -1 | cut -d= -f2- | tr -d '"'"'"'')"
    printf '%s' "${value:-$2}"
}

HTTPS_PORT="$(env_value HTTPS_PORT 8443)"
WEB_BIND_ADDR="$(env_value WEB_BIND_ADDR 127.0.0.1)"
AUTH_USER="$(env_value AUTH_USER admin)"
DOMAIN="$(env_value DOMAIN localhost)"
# Caddy serves the site named by {$DOMAIN:localhost} and has a certificate for
# that name only, so the probe must send it as SNI/Host even when it connects to
# loopback — otherwise the TLS handshake fails and curl reports 000.
CONNECT_ADDR="$WEB_BIND_ADDR"
[ "$CONNECT_ADDR" = "0.0.0.0" ] && CONNECT_ADDR=127.0.0.1
CADDY_URL="https://${DOMAIN}:${HTTPS_PORT}/"
CURL_TLS_OPTS=(-k --resolve "${DOMAIN}:${HTTPS_PORT}:${CONNECT_ADDR}")

container_id() { docker compose ps -q "$1" 2>/dev/null; }
health_of() { # health_of <service> -> healthy|unhealthy|starting|none
    local id
    id="$(container_id "$1")"
    [ -n "$id" ] || { printf 'none'; return; }
    docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$id" 2>/dev/null || printf 'none'
}

wait_healthy() { # wait_healthy <service> <seconds>
    local service="$1" limit="$2" waited=0 state
    while [ "$waited" -lt "$limit" ]; do
        state="$(health_of "$service")"
        case "$state" in
            healthy) printf 'healthy'; return 0 ;;
            unhealthy) printf 'unhealthy'; return 1 ;;
        esac
        sleep 3
        waited=$((waited + 3))
    done
    printf '%s after %ss' "${state:-none}" "$limit"
    return 1
}

# ── 1. prerequisites ─────────────────────────────────────────────────────────
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    record PASS "docker compose available"
else
    record FAIL "docker compose available" "install docker compose and a running daemon"
    printf '%s\n' "${RESULTS[@]}"
    exit 1
fi

if [ -f .env ]; then
    record PASS ".env present"
else
    record FAIL ".env present" "cp .env.example .env and set AUTH_PASS_HASH"
fi

if docker compose config -q >/dev/null 2>&1; then
    record PASS "docker-compose.yaml parses"
else
    record FAIL "docker-compose.yaml parses" "run 'docker compose config' for the reason"
fi

# ── 2. sources.conf ──────────────────────────────────────────────────────────
if validator_out="$("./scripts/validate-sources.sh" conf/sources.conf 2>&1)"; then
    record PASS "conf/sources.conf valid" "$(printf '%s' "$validator_out" | tr '\n' ' ')"
else
    record FAIL "conf/sources.conf valid" "$(printf '%s' "$validator_out" | tail -1)"
fi

# ── 3. start ─────────────────────────────────────────────────────────────────
if [ "$BUILD" = 1 ]; then
    if docker compose build >/dev/null 2>&1; then
        record PASS "docker compose build"
    else
        record FAIL "docker compose build" "re-run without redirecting output"
    fi
fi

if docker compose up -d >/dev/null 2>&1; then
    record PASS "docker compose up -d"
else
    record FAIL "docker compose up -d" "a service failed to be created"
fi

# ── 4. health ────────────────────────────────────────────────────────────────
for service in nfdump nfsen caddy; do
    if state="$(wait_healthy "$service" 180)"; then
        record PASS "$service healthy"
    else
        record FAIL "$service healthy" "$state — docker compose logs $service"
    fi
done

# ── 5. one nfdump in the stack ───────────────────────────────────────────────
collector_version="$(docker compose exec -T nfdump nfdump -V 2>/dev/null | head -1)"
ui_version="$(docker compose exec -T nfsen nfdump -V 2>/dev/null | head -1)"
if [ -n "$collector_version" ] && [ "$collector_version" = "$ui_version" ]; then
    record PASS "nfdump version matches" "$(printf '%s' "$collector_version" | cut -c1-40)"
else
    record FAIL "nfdump version matches" "collector='${collector_version:-none}' ui='${ui_version:-none}'"
fi

# ── 6. the app answers ───────────────────────────────────────────────────────
if docker compose exec -T nfsen curl -fsS --max-time 5 -o /dev/null \
        http://127.0.0.1:9000/favicon.svg >/dev/null 2>&1; then
    record PASS "app serves HTTP on :9000"
else
    record FAIL "app serves HTTP on :9000" "docker compose logs nfsen"
fi

# ── 7. Caddy: TLS + basic auth + proxy ───────────────────────────────────────
curl_code() { # curl_code [--user u:p] -> prints HTTP status, or the error reason
    local err code
    err="$(mktemp)"
    code="$(curl "${CURL_TLS_OPTS[@]}" -s -o /dev/null -w '%{http_code}' --max-time 10 \
        "$@" "$CADDY_URL" 2>"$err")"
    if [ -z "$code" ] || [ "$code" = "000" ]; then
        printf 'connection failed: %s' "$(head -1 "$err" | cut -c1-120)"
    else
        printf 'HTTP %s' "$code"
    fi
    rm -f "$err"
}

if [ -n "$PASSWORD" ]; then
    result="$(curl_code -u "${AUTH_USER}:${PASSWORD}")"
    if [ "$result" = "HTTP 200" ]; then
        record PASS "login through Caddy" "200 at $CADDY_URL"
    else
        record FAIL "login through Caddy" "$result at $CADDY_URL"
    fi
else
    result="$(curl_code)"
    if [ "$result" = "HTTP 401" ]; then
        record PASS "Caddy requires auth" "401 without credentials at $CADDY_URL"
    else
        record FAIL "Caddy requires auth" "expected 401, got $result at $CADDY_URL"
    fi
fi

# ── 8. report ────────────────────────────────────────────────────────────────
printf '\n'
printf '%s\n' "${RESULTS[@]}"
printf '\n'

if [ "$DOWN" = 1 ]; then
    docker compose down >/dev/null 2>&1 && echo "stack stopped (--down)"
fi

if [ "$FAILED" = 1 ]; then
    echo "SMOKE TEST FAILED"
    exit 1
fi
echo "SMOKE TEST PASSED"
