#!/bin/bash
set -euo pipefail

# sources.conf validator — shared by the nfsen and nfdump images (copied to
# /usr/local/bin in both), so the rules cannot drift apart.
#
# Format: one source per line, "device;port;proto"
#   device - display name, also used as a directory name under /data/live
#   port   - UDP port of the collector, 9000-9099
#   proto  - nflow / sflow (only the first letter is interpreted)
#
# On success the normalized list ("name;port;proto", whitespace trimmed,
# CRLF stripped, comments and blank lines dropped) is printed on stdout.
# Errors go to stderr as "sources.conf:<line>: <reason>" and the script
# exits 1.
#
# Validating here instead of in the entrypoints matters: the device name
# becomes a path component (/data/live/<name>) and a PHP array key, so a name
# like '../x', 'a b' or "x'),'a'=>1//" must never reach either consumer.

# Usage: validate-sources.sh [path]   (default: $SOURCES_CONF, then
# /etc/nfsen/sources.conf — the path both containers mount it at)
SOURCES_CONF="${1:-${SOURCES_CONF:-/etc/nfsen/sources.conf}}"
# diagnostics always use the logical name, not the container path
LABEL="sources.conf"

NAME_RE='^[A-Za-z0-9_][A-Za-z0-9._-]{0,63}$'
PORT_RE='^9[0-9]{3}$'

failed=0
output=""
seen_names=" "
seen_ports=" "

fail() {
    printf '%s:%s: %s\n' "$LABEL" "$1" "$2" >&2
    failed=1
}

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

if [[ ! -f "$SOURCES_CONF" ]]; then
    printf '%s: file not found (%s)\n' "$LABEL" "$SOURCES_CONF" >&2
    exit 1
fi

lineno=0
while IFS= read -r raw || [[ -n "$raw" ]]; do
    lineno=$((lineno + 1))
    # CRLF files are common when sources.conf is edited on Windows
    line="${raw%$'\r'}"
    line="$(trim "$line")"

    # tolerate blank lines and comments
    [[ -z "$line" || "$line" == \#* ]] && continue

    if [[ "$line" != *';'* ]]; then
        fail "$lineno" "expected 'device;port;proto', got a line without ';'"
        continue
    fi

    name="$(trim "${line%%;*}")"
    rest="${line#*;}"
    if [[ "$rest" != *';'* ]]; then
        fail "$lineno" "expected 'device;port;proto', got only two fields"
        continue
    fi
    port="$(trim "${rest%%;*}")"
    rest="${rest#*;}"
    proto="$(trim "${rest%%;*}")"

    if [[ "$rest" != "${rest%%;*}" ]]; then
        fail "$lineno" "too many fields — quoting is not supported, use 'device;port;proto'"
        continue
    fi

    if [[ ! "$name" =~ $NAME_RE ]]; then
        fail "$lineno" "invalid device name '$name' (allowed: letters, digits, '.', '_', '-'; must not start with '-' or '.')"
        continue
    fi
    if [[ ! "$port" =~ $PORT_RE ]]; then
        fail "$lineno" "invalid port '$port' for '$name' (expected 9000-9099)"
        continue
    fi
    if [[ -z "$proto" ]]; then
        fail "$lineno" "missing protocol for '$name' (expected nflow or sflow)"
        continue
    fi
    case "$seen_names" in
        *" $name "*)
            fail "$lineno" "duplicate device name '$name'"
            continue
            ;;
    esac
    case "$seen_ports" in
        *" $port "*)
            fail "$lineno" "duplicate port '$port' (each source needs its own port)"
            continue
            ;;
    esac

    seen_names="$seen_names$name "
    seen_ports="$seen_ports$port "
    output="${output}${name};${port};${proto}"$'\n'
done <"$SOURCES_CONF"

if [[ -z "$output" && "$failed" -eq 0 ]]; then
    printf '%s: no sources defined in %s (empty file — is the bind mount in place?)\n' \
        "$LABEL" "$SOURCES_CONF" >&2
    exit 1
fi

if [[ "$failed" -ne 0 ]]; then
    exit 1
fi

printf '%s' "$output"
