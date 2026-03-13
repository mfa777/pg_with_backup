#!/bin/bash
set -eux

# Reusable PostgreSQL extension installer
# Usage: install-extensions.sh <extension> [version] [release]
#
# Supported extensions:
#   pgvector    - builds from source (version arg ignored)
#   vchord      - installs .deb from GitHub (version required)
#   pg_search   - installs .deb from GitHub with distro detection (version required)

EXTENSION="${1:?Usage: install-extensions.sh <extension> [version] [release]}"
VERSION="${2:-}"
RELEASE="${3:-1}"

PG_MAJOR="$(echo "${POSTGRES_VERSION:?POSTGRES_VERSION must be set}" | cut -d. -f1)"
ARCH="$(dpkg --print-architecture)"

install_pgvector() {
    if apt-get update && apt-get install -y --no-install-recommends "postgresql-server-dev-${PG_MAJOR}"; then
        git clone --depth 1 https://github.com/pgvector/pgvector.git /tmp/pgvector
        cd /tmp/pgvector
        make && make install
        rm -rf /tmp/pgvector
    else
        echo "Skipping pgvector build due to dependency issues"
    fi
    rm -rf /var/lib/apt/lists/*
}

install_vchord() {
    local ver="${VERSION:?vchord requires a version argument}"
    local pkg="postgresql-${PG_MAJOR}-vchord_${ver}-${RELEASE}_${ARCH}.deb"
    wget --tries=3 -O "/tmp/${pkg}" \
        "https://github.com/tensorchord/VectorChord/releases/download/${ver}/${pkg}"
    apt-get update
    apt-get install -y --no-install-recommends "/tmp/${pkg}"
    rm -f "/tmp/${pkg}"
    rm -rf /var/lib/apt/lists/*
}

install_pg_search() {
    local ver="${VERSION:?pg_search requires a version argument}"
    . /etc/os-release
    local pg_search_url=""
    for distro in "${VERSION_CODENAME:-}" bookworm trixie noble jammy; do
        [ -n "${distro}" ] || continue
        local candidate="https://github.com/paradedb/paradedb/releases/download/v${ver}/postgresql-${PG_MAJOR}-pg-search_${ver}-${RELEASE}PARADEDB-${distro}_${ARCH}.deb"
        if wget -q --spider "${candidate}"; then
            pg_search_url="${candidate}"
            break
        fi
    done
    if [ -z "${pg_search_url}" ]; then
        echo "Could not find pg_search package for postgresql-${PG_MAJOR} (${ARCH}) in v${ver}" >&2
        exit 1
    fi
    wget --tries=3 -O /tmp/pg_search.deb "${pg_search_url}"
    apt-get update
    apt-get install -y --no-install-recommends /tmp/pg_search.deb
    rm -f /tmp/pg_search.deb
    rm -rf /var/lib/apt/lists/*
}

case "$EXTENSION" in
    pgvector)   install_pgvector ;;
    vchord)     install_vchord ;;
    pg_search)  install_pg_search ;;
    *)
        echo "Unknown extension: $EXTENSION" >&2
        echo "Supported: pgvector, vchord, pg_search" >&2
        exit 1
        ;;
esac
