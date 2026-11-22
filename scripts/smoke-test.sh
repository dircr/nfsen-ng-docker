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
HTTP_PORT="$(env_value HTTP_PORT 8080)"
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
CURL_HTTP_OPTS=(-k --resolve "${DOMAIN}:${HTTP_PORT}:${CONNECT_ADDR}")
HTTP_URL="http://${DOMAIN}:${HTTP_PORT}/"

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

# Mode of .env: it holds the basic-auth hash, so it must not be group/world
# readable. stat differs between BSD (macOS) and GNU, hence the probe.
if [ -f .env ]; then
    env_mode="$(stat -f '%Lp' .env 2>/dev/null || stat -c '%a' .env 2>/dev/null)"
    if [ -n "$env_mode" ] && [ "$env_mode" != "600" ]; then
        record FAIL ".env mode is 0600" "is $env_mode — run: chmod 600 .env"
    else
        record PASS ".env mode is 0600"
    fi
fi

# A placeholder hash lets the stack look configured while the password is
# public knowledge; Caddy rejects it only at start-up, with an error that
# names neither the file nor the variable. Starting anyway would take the UI
# down, so both of these abort the run instead of reporting and continuing.
FATAL=0
if grep -qE '^[[:space:]]*AUTH_PASS_HASH=[[:space:]]*(\$\$)?REPLACE_WITH_GENERATED_HASH' .env 2>/dev/null; then
    FATAL=1
    record FAIL "AUTH_PASS_HASH is set" "still the placeholder — see the hash-password step in README"
else
    record PASS "AUTH_PASS_HASH is set"
fi

# Compose gives the process environment precedence over .env, so an exported
# AUTH_PASS_HASH silently wins over the file. Anything that sources .env
# instead of parsing it expands the $$ escaping to a shell PID and the hash
# arrives corrupted (Caddy then exits with "illegal base64 data").
if [ -n "${AUTH_PASS_HASH:-}" ] && [ "${AUTH_PASS_HASH}" != "$(env_value AUTH_PASS_HASH '')" ]; then
    FATAL=1
    record FAIL "AUTH_PASS_HASH from .env is not shadowed" \
        "the environment carries a different value — run: env -u AUTH_PASS_HASH ./scripts/smoke-test.sh"
else
    record PASS "AUTH_PASS_HASH from .env is not shadowed"
fi

if [ "$FATAL" = 1 ]; then
    printf '\n'
    printf '%s\n' "${RESULTS[@]}"
    printf '\nNot starting the stack: a broken AUTH_PASS_HASH stops caddy and takes the UI down.\n'
    exit 1
fi

# DOMAIN as a bare IP: browsers send no SNI for IP literals, so Caddy needs to be
# told which certificate to fall back to. Without that the handshake dies with
# "tlsv1 alert internal error" and every HTTPS check below reports a meaningless
# 000, which reads like a broken stack instead of a missing setting.
case "$DOMAIN" in
    *[A-Za-z]*|'') ;;   # a hostname (or unset): SNI is always sent, nothing to check
    *)
        if [ "$(env_value CADDY_DEFAULT_SNI localhost)" != "$DOMAIN" ]; then
            record FAIL "CADDY_DEFAULT_SNI matches the IP DOMAIN" \
                "DOMAIN=$DOMAIN is an IP literal — set CADDY_DEFAULT_SNI=$DOMAIN in .env, otherwise HTTPS cannot complete a handshake"
        else
            record PASS "CADDY_DEFAULT_SNI matches the IP DOMAIN"
        fi
        ;;
esac

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

# ── 4b. guards for the failure modes that look like "it works" ──────────────
#
# A mangled hash reaches Caddy as a non-hash and the container exits; check what
# the process actually got rather than trusting .env. `$2a` is bcrypt; `$2b`/
# `$2y` are equivalent variants produced by other tools.
hash_prefix="$(docker compose exec -T caddy printenv AUTH_PASS_HASH 2>/dev/null | cut -c1-3)"
case "$hash_prefix" in
    '$2a'|'$2b'|'$2y') record PASS "Caddy received an intact hash" ;;
    *) record FAIL "Caddy received an intact hash" \
           "got '${hash_prefix}…' — see Troubleshooting: illegal base64 data" ;;
esac

# The UI port must never be published: the app has no authentication of its own.
if [ -n "$(docker compose port nfsen 9000 2>/dev/null)" ]; then
    record FAIL "app port 9000 is not published" \
        "remove the ports: entry for nfsen — Caddy is the only way in"
else
    record PASS "app port 9000 is not published"
fi

# A long-running container can keep a stale view of its bind mount, in which
# case it serves a config that is no longer in the repo and `caddy reload`
# cannot even read the file.
if docker compose exec -T caddy test -f /etc/caddy/Caddyfile 2>/dev/null; then
    record PASS "Caddyfile is visible inside caddy"
else
    record FAIL "Caddyfile is visible inside caddy" \
        "stale mount — docker compose up -d --force-recreate caddy"
fi

# The redirect has to name the port that is actually published, otherwise
# http://host:HTTP_PORT lands on HTTPS :443 where nothing listens.
redirect_url="$(curl "${CURL_HTTP_OPTS[@]}" -s -o /dev/null -w '%{redirect_url}' --max-time 10 "$HTTP_URL" 2>/dev/null)"
case "$redirect_url" in
    *":${HTTPS_PORT}/"*) record PASS "HTTP redirects to the published HTTPS port" "$redirect_url" ;;
    *) record FAIL "HTTP redirects to the published HTTPS port" \
           "got '${redirect_url:-none}', expected port ${HTTPS_PORT}" ;;
esac

# HTTP/3 is disabled on purpose: the host publishes no UDP for it, so Caddy
# must not advertise an h3 endpoint that cannot be reached.
if curl "${CURL_TLS_OPTS[@]}" -s -D - -o /dev/null --max-time 10 "$CADDY_URL" 2>/dev/null | grep -qi '^alt-svc:'; then
    record FAIL "no unreachable alt-svc advertisement" \
        "Caddy advertises HTTP/3 on a port that is not published"
else
    record PASS "no unreachable alt-svc advertisement"
fi

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

# PHP does not read TZ; the entrypoint passes date.timezone per process. Without
# that the UI renders every timestamp in UTC while nfcapd names its files in local
# time — a one or two hour shift in every graph, with nothing visibly broken.
TZ_VALUE="$(env_value TZ UTC)"
php_args="$(docker compose exec -T nfsen sh -c 'ps -o args= -C php 2>/dev/null | head -1')"
case "$php_args" in
    *"date.timezone=${TZ_VALUE}"*) record PASS "PHP timezone matches TZ" "$TZ_VALUE" ;;
    *) record FAIL "PHP timezone matches TZ" \
           "php is not running with -d date.timezone=${TZ_VALUE} (got: ${php_args:-none})" ;;
esac

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
        # Headers are only reachable on a served response: the deferred `header`
        # handler does not run for the 401 that basic_auth produces, so this is
        # the one probe that can see them.
        hdrs="$(curl "${CURL_TLS_OPTS[@]}" -u "${AUTH_USER}:${PASSWORD}" -s -D - -o /dev/null \
            --max-time 10 "$CADDY_URL" 2>/dev/null)"
        missing=""
        for h in x-content-type-options x-frame-options referrer-policy \
                 permissions-policy content-security-policy; do
            printf '%s' "$hdrs" | grep -qi "^${h}:" || missing="$missing $h"
        done
        if [ -z "$missing" ]; then
            record PASS "security headers present"
        else
            record FAIL "security headers present" "missing:$missing"
        fi
        if printf '%s' "$hdrs" | grep -qi '^server:'; then
            record FAIL "Server header suppressed" "the -Server directive did not take effect"
        else
            record PASS "Server header suppressed"
        fi
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
