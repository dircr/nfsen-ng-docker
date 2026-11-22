# nfsen-ng 1.x is a ground-up rewrite: PHP 8.4 + OpenSwoole (php-via) serves the
# UI *and* its static assets from a single process on port 9000 — no Apache, no
# php-fpm, no mod_proxy_fcgi.
#
# Upstream publishes a prebuilt image on ghcr.io, but manifest lists for every
# tag (1.0.0-beta.7, latest, edge) contain linux/amd64 only — no linux/arm64, so
# it cannot run on Apple Silicon without emulation. Building from the pinned tag
# keeps the image native, makes it reproducible from this repository, and gives
# the UI the same nfdump build as the collector.
#
# The only patch this repository adds on top of upstream's own image recipe is
# the wrapper that turns conf/sources.conf into NFSEN_SOURCES (last stage).

# ── application sources + composer vendor ─────────────────────────────────────
# Base image pinned by digest (see nfdump/Dockerfile for the reasoning). The
# composer image only supplies the vendor/ directory; its PHP version is
# irrelevant.
FROM composer:2@sha256:50ea4d33fdcde1adb0f045547295faa1548b33872e5f789dae5b02ce2fb5de93 AS vendor

ARG NFSEN_NG_VERSION=v1.0.0-beta.7
# Commit behind that tag. The tag can be re-pointed (and a `git clone --branch`
# would silently follow it); the commit cannot. The clone still uses the tag so
# the checkout is shallow, and the assertion below is what makes it safe.
ARG NFSEN_NG_COMMIT=903d226a8c97cf4bc007d161fe77d7a5dff2a1b9

WORKDIR /app
RUN set -eux; \
    git clone --depth 1 --branch "${NFSEN_NG_VERSION}" https://github.com/mbolli/nfsen-ng.git .; \
    test "$(git rev-parse HEAD)" = "${NFSEN_NG_COMMIT}"; \
    rm -rf .git

# --ignore-platform-reqs: the PHP extensions (openswoole, inotify, rrd,
# mbstring) only exist in the runtime stage; their presence is asserted there.
RUN composer install --no-dev --optimize-autoloader --no-interaction --no-progress \
        --ignore-platform-reqs

# Drop what the runtime does not need (docs, tests, CI config, frontend tooling).
# A separate RUN keeps the vendor layer cacheable while this list changes.
# hadolint ignore=DL3059
RUN rm -rf tests book .github .php-cs-fixer.php .rector.php phpstan.neon phpunit.xml.dist \
        biome.json package.json pnpm-lock.yaml

# ── nfdump, compiled once and shared with the collector ───────────────────────
# Same version as nfdump/Dockerfile: the UI reads the files the collector writes,
# and nfdump's file format is only stable within a minor series.
FROM debian:13-slim@sha256:a72b4433de1cf7d6bae0c4cee74d0547f58601a643b3375f070c51600d63b6b2 AS nfdump

ARG NFDUMP_VERSION=1.7.10
# Same archive, same checksum as nfdump/Dockerfile: one nfdump version, verified.
ARG NFDUMP_SHA256=cc529734017cb740e499f564a17ff46d3fbc2e8392464a54b3e6ff403cfa43cf

# hadolint ignore=DL3008
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        build-essential autoconf automake libtool flex bison pkg-config \
        libbz2-dev zlib1g-dev libssl-dev libzstd-dev ca-certificates curl unzip; \
    rm -rf /var/lib/apt/lists/*

WORKDIR /tmp
RUN set -eux; \
    curl -fsSL -o nfdump.zip \
        "https://github.com/phaag/nfdump/archive/refs/tags/v${NFDUMP_VERSION}.zip"; \
    echo "${NFDUMP_SHA256}  nfdump.zip" > nfdump.sha256; \
    sha256sum -c nfdump.sha256; \
    unzip -q nfdump.zip; \
    rm -f nfdump.zip

WORKDIR /tmp/nfdump-${NFDUMP_VERSION}
RUN set -eux; \
    ./autogen.sh; \
    ./configure --prefix=/usr/local/nfdump; \
    make -j"$(nproc)"; \
    make install

# ── runtime ──────────────────────────────────────────────────────────────────
FROM php:8.4-cli@sha256:6b13a8678b38ca38e4e3950be57b664ed8c8706131a0586111f68792aede4c58

LABEL org.opencontainers.image.title="nfsen-ng" \
      org.opencontainers.image.description="nfsen-ng UI on php-via/OpenSwoole with nfdump" \
      org.opencontainers.image.source="https://github.com/dircr/nfsen-ng-docker" \
      org.opencontainers.image.licenses="Apache-2.0"

ARG NFDUMP_VERSION=1.7.10

#   DL3008: packages are deliberately unpinned (Debian stable + security
#           updates); the nfdump and extension versions are asserted below.
# hadolint ignore=DL3008
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        ca-certificates curl netbase bind9-host procps unzip; \
    rm -rf /var/lib/apt/lists/*

COPY --from=nfdump /usr/local/nfdump /usr/local/nfdump
ENV PATH="/usr/local/nfdump/bin:${PATH}"
# nfdump installs libnfdump/libnffile as *shared* libraries under
# /usr/local/nfdump/lib; the build stage's ld.so.cache does not travel with the
# copied tree, so register the directory — otherwise nfdump (and every call the
# UI makes to it) dies with "error while loading shared libraries".
RUN set -eux; \
    echo "/usr/local/nfdump/lib" > /etc/ld.so.conf.d/nfdump.conf; \
    ldconfig

# OpenSwoole (the HTTP server), inotify (the import daemon's watch on
# profiles-data/live), brotli (php-via compresses its own static assets), rrd
# (the default time-series backend) and mbstring (a composer requirement).
# The installer pulls the matching -dev packages itself and cleans them up.
#   rrd 2.0.4 passes char ** where newer librrd wants const char **, an error
#   since GCC 14 — tolerated rather than patched, since the mismatch is
#   harmless and librrd in Debian stable predates it anyway.
# Pinned on purpose: `.../releases/latest/download/...` would execute whatever
# the installer's newest release is at build time, so two builds of this
# repository could differ without a commit here. Bump deliberately.
ARG PHP_EXTENSIONS_INSTALLER_VERSION=2.13.2
ADD --chmod=0755 https://github.com/mlocati/docker-php-extension-installer/releases/download/${PHP_EXTENSIONS_INSTALLER_VERSION}/install-php-extensions /usr/local/bin/
#   DL4006: the pipeline is an assertion; `set -eux` already fails on error.
# hadolint ignore=DL4006
RUN set -eux; \
    CFLAGS="-O2 -Wno-error=incompatible-pointer-types" \
        install-php-extensions openswoole inotify brotli mbstring rrd; \
    for ext in openswoole inotify brotli mbstring rrd; do php -m | grep -qx "$ext"; done; \
    php -r 'exit(class_exists("PDO") && in_array("sqlite", PDO::getAvailableDrivers(), true) ? 0 : 1);'

# One worker holds every tab, the import and the top-N collector, and a crash
# ends them all. PHP's default 128M leaves little room: a 10,000-row Flows
# listing alone takes the heap to about 75 MB.
# hadolint ignore=DL3059
RUN echo 'memory_limit = 512M' > "$PHP_INI_DIR/conf.d/nfsen-ng.ini"

# Persistent app data lives on one volume, separate from the code, so it
# survives image upgrades: rrd/ (RRD databases) and state/ (preferences.json,
# alert rule state, nfsen-ng.sqlite with saved filters, alert history and
# per-interval top-N data). docker-compose mounts ./nfsen-state here.
ENV NFSEN_RRD_PATH="/var/lib/nfsen-ng/rrd" \
    NFSEN_STATE_DIR="/var/lib/nfsen-ng/state"
RUN mkdir -p /var/lib/nfsen-ng/rrd /var/lib/nfsen-ng/state

COPY --from=vendor /app /var/www/html/nfsen-ng
WORKDIR /var/www/html/nfsen-ng

# The wrapper validates conf/sources.conf (the same validator the collector
# runs), exports NFSEN_SOURCES and execs the application server.
COPY scripts/validate-sources.sh /usr/local/bin/validate-sources.sh
COPY nfsen-ng/entrypoint.sh /usr/local/bin/nfsen-ng-entrypoint.sh
# /etc/nfsen holds sources.conf. docker-compose mounts ./conf here as a
# directory; the placeholder keeps the image usable without the mount and lets
# the entrypoint explain what is missing instead of failing inside the app.
RUN set -eux; \
    chmod +x /usr/local/bin/nfsen-ng-entrypoint.sh /usr/local/bin/validate-sources.sh; \
    mkdir -p /etc/nfsen; \
    touch /etc/nfsen/sources.conf

# Assert what the image is for: the app's autoloader, the server extension, the
# exact nfdump the files were written with, and the binaries the UI shells out
# to. A missing php-via package (a composer lock that names an unpublished
# dev branch) exits 0 from composer and would only fail at the first request.
# hadolint ignore=DL4006
RUN set -eux; \
    php -r 'require "/var/www/html/nfsen-ng/vendor/autoload.php"; \
        exit(class_exists("Mbolli\\PhpVia\\Via") ? 0 : 1);'; \
    nfdump -V 2>&1 | grep -qE "Version: *${NFDUMP_VERSION}-"; \
    command -v nfcapd; \
    command -v nfexpire; \
    php -l /var/www/html/nfsen-ng/backend/app.php > /dev/null

EXPOSE 9000

# CMD is empty on purpose: the wrapper receives no arguments and therefore runs
# the server. `docker run <image> php -v` still works — with arguments the
# wrapper execs them directly, skipping the config validation.
CMD []
ENTRYPOINT ["/usr/local/bin/nfsen-ng-entrypoint.sh"]
