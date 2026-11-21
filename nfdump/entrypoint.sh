#!/bin/bash
set -euo pipefail

# nfdump collector entrypoint
#
# sources.conf format (one source per line): "device;port;proto"
#   device - display name, e.g. 'my-awesome-router'
#   port   - unique value between 9000 and 9099
#   proto  - nflow or sflow
#
# Starts one collector (nfcapd for nflow, sfcapd for sflow) per source,
# verifies they are up, then monitors them. If a collector dies, the
# container exits so the restart policy brings it back.

# Run an explicit command instead of the normal start-up sequence, e.g.
#   docker run --rm <image> nfdump -V
# Without this the arguments would be ignored and the entrypoint would look
# for sources.conf in a container that has no /etc/nfsen mounted.
if [ "$#" -gt 0 ]; then
    exec "$@"
fi

SOURCES_CONF="${SOURCES_CONF:-/etc/nfsen/sources.conf}"
export SOURCES_CONF
VALIDATE_SOURCES="/usr/local/bin/validate-sources.sh"
# normalized copy of sources.conf (validated, one "name;port;proto" per line)
VALIDATED_SOURCES="/tmp/sources.validated"

# Flow data retention: nfcapd files older than FLOW_RETENTION_DAYS are
# deleted by nfexpire (once at startup, then hourly from the monitor loop).
# 0 disables expiry. Digits only — anything else falls back to 30.
FLOW_RETENTION_DAYS="${FLOW_RETENTION_DAYS:-30}"
if ! [[ "$FLOW_RETENTION_DAYS" =~ ^[0-9]+$ ]]; then
    echo >&2 "Warning: FLOW_RETENTION_DAYS='$FLOW_RETENTION_DAYS' is not a number — falling back to 30"
    FLOW_RETENTION_DAYS=30
fi

# pid per device name, filled by start_collector and used for the liveness
# checks (kill -0). Matching on the command line instead (pgrep -f "fcapd -I
# <name>") treats the device name as a regexp, reports a false alarm when the
# name contains a bracket expression, and matches any fcapd process at all
# when the name is ".*".
declare -A PIDS=()

# Expire flow data per source. nfexpire removes nfcapd files older than the
# lifetime and cleans up empty day directories. A failure must not kill the
# container (set -e), so guard it — retention is best-effort.
expire_flow_data() {
    local host port proto
    while IFS=';' read -r host port proto; do
        [[ -z "$host" ]] && continue
        echo "Expiring flow data for '$host' (older than ${FLOW_RETENTION_DAYS}d)"
        if ! nfexpire -e "/data/live/$host" -t "${FLOW_RETENTION_DAYS}d"; then
            echo >&2 "Warning: nfexpire failed for '$host' (port $port) — continuing"
        fi
    done < "$VALIDATED_SOURCES"
}

if [ ! -f "$SOURCES_CONF" ]; then
    # Distinguish "bind mount missing" from "mounted as a directory" (a
    # host file mounted onto a path Docker had to create as a directory) —
    # the listing below shows which one it is.
    echo >&2 "Error: $SOURCES_CONF is not a regular file — is the ./conf directory mounted here?"
    ls -la "$(dirname "$SOURCES_CONF")" >&2 2>&1 || true
    exit 1
fi

# The device name becomes a directory (/data/live/<name>), so it is validated
# before anything is created. Both entrypoints use the same validator.
if ! "$VALIDATE_SOURCES" > "$VALIDATED_SOURCES"; then
    echo >&2 "Error: invalid $SOURCES_CONF — refusing to start"
    exit 1
fi

# ./profiles-data is bind-mounted and usually arrives owned by the host user,
# while the collectors run as the image user (1000:1000 in compose). Without a
# writable /data/live nfcapd dies instantly and the container restarts in a
# loop with no explanation.
if ! mkdir -p /data/live 2>/dev/null || [ ! -w /data/live ]; then
    echo >&2 "Error: /data/live is not writable as uid $(id -u) — fix the ownership once:"
    echo >&2 "  docker run --rm -v \"\$PWD/profiles-data:/data\" alpine chown -R 1000:1000 /data"
    exit 1
fi

start_collector() {
    local host="$1" port="$2" proto="$3"
    local collector

    case "$proto" in
        n*) collector="nfcapd" ;;
        s*) collector="sfcapd" ;;
        *)
            echo >&2 "Error: unknown protocol '$proto' for source '$host' (expected nflow or sflow)"
            return 1
            ;;
    esac

    if ! command -v "$collector" >/dev/null 2>&1; then
        echo >&2 "Error: $collector not found for source '$host' (protocol $proto)"
        return 1
    fi

    if ! mkdir -p "/data/live/$host" 2>/dev/null; then
        echo >&2 "Error: cannot create /data/live/$host — is profiles-data writable by uid $(id -u)? (hint: chown -R 1000:1000 profiles-data)"
        exit 1
    fi

    # -T all: store the optional extension tags (interfaces, AS, ...) the
    # exporters send; without it nfsen-ng's interface/AS views have nothing to
    # show. -S 1 is nfdump's %Y/%m/%d hierarchy — the layout nfsen-ng 1.x
    # requires (it refuses flat source directories).
    echo "\$ $collector -I $host -w /data/live/$host -S 1 -T all -p $port"
    "$collector" -I "$host" -w "/data/live/$host" -S 1 -T all -p "$port" &
    PIDS["$host"]=$!
}

while IFS=';' read -r host port proto; do
    [[ -z "$host" ]] && continue
    start_collector "$host" "$port" "$proto"
    sleep 0.1
done < "$VALIDATED_SOURCES"

sleep 1

# verify every collector is up
while IFS=';' read -r host port proto; do
    [[ -z "$host" ]] && continue
    if ! kill -0 "${PIDS[$host]}" 2>/dev/null; then
        echo >&2 "Error: collector for '$host' (port $port) failed to start"
        exit 1
    fi
done < "$VALIDATED_SOURCES"

echo "Ready"

# initial retention pass (then hourly from the monitor loop)
expire_flow_data

# monitor: exit if a collector dies so the restart policy kicks in
iter=0
while true; do
    sleep 60
    iter=$((iter + 1))
    # hourly retention pass (60 iterations x 60s)
    if [ $((iter % 60)) -eq 0 ]; then
        expire_flow_data
    fi
    while IFS=';' read -r host port proto; do
        [[ -z "$host" ]] && continue
        if ! kill -0 "${PIDS[$host]}" 2>/dev/null; then
            echo >&2 "Missing process for $host (port $port) — exiting for restart"
            exit 1
        fi
    done < "$VALIDATED_SOURCES"
done
