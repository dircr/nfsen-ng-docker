# nfdump collectors (nfcapd / sfcapd / nfexpire) compiled from source in a
# throwaway build stage: Debian 13 ships 1.7.5, but nfdump 1.7.9 fixed remotely
# triggerable crashes in the collectors and file parsers, and nfsen-ng 1.x
# (the image the UI now runs) warns below 1.7.10 on its Health page. Building
# the same version in both images also removes the version-parity question
# entirely: there is exactly one nfdump in the stack.
FROM debian:13-slim AS build

ARG NFDUMP_VERSION=1.7.10

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
    unzip -q nfdump.zip; \
    rm -f nfdump.zip

WORKDIR /tmp/nfdump-${NFDUMP_VERSION}
RUN set -eux; \
    ./autogen.sh; \
    ./configure --prefix=/usr/local/nfdump; \
    make -j"$(nproc)"; \
    make install

FROM debian:13-slim

LABEL org.opencontainers.image.title="nfdump collector" \
      org.opencontainers.image.description="NetFlow/sFlow collector (nfcapd/sfcapd)" \
      org.opencontainers.image.source="https://github.com/dircr/nfsen-ng-docker" \
      org.opencontainers.image.licenses="BSD-3-Clause"

ARG NFDUMP_VERSION=1.7.10

# Runtime libraries for the compiled binaries (bzip2/zlib/OpenSSL/zstd are
# picked up by configure when present) + procps for pgrep in the healthcheck.
#   DL3008: packages are deliberately unpinned (Debian stable + security
#           updates); the nfdump version is asserted below instead.
# hadolint ignore=DL3008
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        libbz2-1.0 zlib1g libssl3t64 libzstd1 procps; \
    rm -rf /var/lib/apt/lists/*

COPY --from=build /usr/local/nfdump /usr/local/nfdump
ENV PATH="/usr/local/nfdump/bin:${PATH}"
# nfdump installs libnfdump/libnffile as *shared* libraries under
# /usr/local/nfdump/lib, and the binaries link against them. The build stage's
# ld.so.cache does not travel with the copied tree, so the loader has to be
# told where they are — without this every binary fails with "error while
# loading shared libraries".
RUN set -eux; \
    echo "/usr/local/nfdump/lib" > /etc/ld.so.conf.d/nfdump.conf; \
    ldconfig

# Assert the binaries *and* the version: shipping an image without sfcapd
# would silently break every sflow source at runtime, and a wrong version
# would go unnoticed until the UI shows nothing.
# hadolint ignore=DL4006
RUN set -eux; \
    for bin in nfcapd nfdump nfexpire sfcapd; do command -v "$bin"; done; \
    nfdump -V 2>&1 | grep -qE "Version: *${NFDUMP_VERSION}-"

WORKDIR /app
COPY nfdump/entrypoint.sh .
COPY scripts/validate-sources.sh /usr/local/bin/validate-sources.sh
# /etc/nfsen holds sources.conf. docker-compose mounts ./conf here as a
# directory (a single-file bind mount is unreliable on some daemons, and this
# container's rootfs is read-only, so Docker could not create the mountpoint).
# The directory and an empty placeholder file are created so the image is also
# usable without the mount — the entrypoint then fails with a clear message.
RUN chmod a+x /app/entrypoint.sh /usr/local/bin/validate-sources.sh \
    && mkdir -p /etc/nfsen \
    && touch /etc/nfsen/sources.conf

# hadolint ignore=DL3025
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD pgrep -f fcapd > /dev/null || exit 1

ENTRYPOINT [ "/bin/bash", "/app/entrypoint.sh" ]
