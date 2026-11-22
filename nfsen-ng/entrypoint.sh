#!/bin/bash
set -euo pipefail

# nfsen-ng 1.x start-up wrapper (php-via / OpenSwoole, port 9000).
#
# conf/sources.conf stays the single source of truth for this stack: the
# collector reads it to start one nfcapd/sfcapd per line, and the UI needs the
# same source names — nfsen-ng 1.x takes them from NFSEN_SOURCES, so this
# wrapper validates the file and passes the names on. Without it there would
# be two places to add a source, and they would drift.

SOURCES_CONF="${SOURCES_CONF:-/etc/nfsen/sources.conf}"
VALIDATE_SOURCES="/usr/local/bin/validate-sources.sh"
VALIDATED_SOURCES="/tmp/sources.validated"
APP="/var/www/html/nfsen-ng/backend/app.php"

# An explicit command replaces the normal start-up sequence, e.g.
#   docker run --rm <image> php --version
# The base image's CMD is cleared in the Dockerfile, so compose passes nothing.
if [ "$#" -gt 0 ]; then
    exec "$@"
fi

if [ ! -f "$SOURCES_CONF" ]; then
    echo >&2 "Error: $SOURCES_CONF is not a regular file — is the ./conf directory mounted here?"
    ls -la "$(dirname "$SOURCES_CONF")" >&2 || true
    exit 1
fi

if ! "$VALIDATE_SOURCES" > "$VALIDATED_SOURCES"; then
    echo >&2 "Error: invalid $SOURCES_CONF — refusing to start"
    exit 1
fi

# "router1;9000;nflow" per line -> NFSEN_SOURCES=router1[,router2...]
# The port and protocol columns are the collector's business; nfsen-ng 1.x
# only needs the names, which double as the directory names under
# profiles-data/live/.
if [ -n "${NFSEN_SOURCES:-}" ]; then
    echo >&2 "Warning: NFSEN_SOURCES='$NFSEN_SOURCES' from the environment is ignored —" \
                >&2 "         $SOURCES_CONF is the source of truth for this stack"
fi
NFSEN_SOURCES="$(cut -d';' -f1 "$VALIDATED_SOURCES" | paste -sd, -)"
export NFSEN_SOURCES
echo "Sources from $SOURCES_CONF: $NFSEN_SOURCES"

# nfsen-ng validates the capture tree at boot and refuses to start when a
# source directory is missing ("Source directory does not exist"). The
# collector creates <profiles>/live/<source>/ before it starts nfcapd, but a
# plain `docker compose restart` does not order the two services, so wait for
# the directories instead of dying inside the app with a stack trace.
profiles_dir="${NFSEN_NFDUMP_PROFILES:-/var/nfdump/profiles-data}"
profile_name="${NFSEN_NFDUMP_PROFILE:-live}"
IFS=',' read -r -a source_names <<< "$NFSEN_SOURCES"
missing=""
for _ in $(seq 1 30); do
    missing=""
    for source in "${source_names[@]}"; do
        [ -d "$profiles_dir/$profile_name/$source" ] || missing="$missing $source"
    done
    [ -z "$missing" ] && break
    sleep 1
done
if [ -n "$missing" ]; then
    echo >&2 "Error: no capture directory for:$missing"
    echo >&2 "  expected: $profiles_dir/$profile_name/<source>/"
    echo >&2 "  the collector creates it on start — is nfdump running and healthy?"
    echo >&2 "  (docker compose logs nfdump)"
    exit 1
fi

# RRD databases and the SQLite store live on a bind mount (./nfsen-state); an
# empty host directory hides the ones the image creates, and nfsen-ng then
# fails on its first write, so check before starting.
for dir in "${NFSEN_RRD_PATH:-/var/lib/nfsen-ng/rrd}" "${NFSEN_STATE_DIR:-/var/lib/nfsen-ng/state}"; do
    if ! mkdir -p "$dir" 2>/dev/null || [ ! -w "$dir" ]; then
        echo >&2 "Error: $dir is not writable as uid $(id -u) — is ./nfsen-state mounted there?"
        echo >&2 "  fix the ownership once (the container runs as the collector's uid):"
        echo >&2 "  docker run --rm -v \"\$PWD/nfsen-state:/s\" alpine chown -R 1000:1000 /s"
        exit 1
    fi
done

echo "Starting nfsen-ng on port 9000"
# PHP does not read TZ (that is libc); its date functions use the date.timezone
# ini setting, and the base image pins that to UTC. With TZ=Europe/Warsaw the app
# would render every timestamp in UTC while nfcapd names its files in local time —
# a one or two hour shift in every graph, which the Health page reports as
# "php.ini date.timezone='UTC' overrides TZ env var". Passing it per process keeps
# both in sync and works with the read-only root filesystem (nothing to write).
exec php -d "date.timezone=${TZ:-UTC}" "$APP"
