#!/bin/bash
set -eo pipefail

# Simplified environment preparation script for wal-g
# Goals:
# - Ensure a usable private key is available at /var/lib/postgresql/.ssh/walg_key
# - Make a default /var/lib/postgresql/.ssh/id_rsa for plain `ssh` calls
# - Populate /var/lib/postgresql/.walg_env with the sensible variables

prepare_ssh_key() {
    echo "Preparing SSH key for wal-g..."

    mkdir -p /var/lib/postgresql/.ssh
    chown postgres:postgres /var/lib/postgresql/.ssh || true
    chmod 700 /var/lib/postgresql/.ssh || true

    target="/var/lib/postgresql/.ssh/walg_key"

    if [ -n "${WALG_SSH_PRIVATE_KEY:-}" ]; then
        echo "Using WALG_SSH_PRIVATE_KEY (base64)"
        echo "$WALG_SSH_PRIVATE_KEY" | base64 -d > "$target"
    elif [ -n "${WALG_SSH_PRIVATE_KEY_PATH:-}" ] && [ -f "$WALG_SSH_PRIVATE_KEY_PATH" ]; then
        echo "Using key file from WALG_SSH_PRIVATE_KEY_PATH: $WALG_SSH_PRIVATE_KEY_PATH"
        # Always copy to a container-local path so permissions can be set regardless of mount mode
        cp "$WALG_SSH_PRIVATE_KEY_PATH" "$target"
    else
        echo "Warning: No SSH private key configured for wal-g"
        return 1
    fi

    chmod 600 "$target" || true
    chown postgres:postgres "$target" || true

    # Ensure plain `ssh` can find a default key (some tests call ssh without -i)
    if [ ! -f /var/lib/postgresql/.ssh/id_rsa ] || [ "$(realpath /var/lib/postgresql/.ssh/id_rsa 2>/dev/null || true)" != "$target" ]; then
        cp -f "$target" /var/lib/postgresql/.ssh/id_rsa
        chmod 600 /var/lib/postgresql/.ssh/id_rsa || true
        chown postgres:postgres /var/lib/postgresql/.ssh/id_rsa || true
    fi

    export WALG_SSH_PRIVATE_KEY_PATH="$target"    

    # Add host to known_hosts unless explicitly skipped
    if [ -n "${WALG_SSH_PREFIX:-}" ] && [ "${SKIP_SSH_KEYSCAN:-0}" != "1" ]; then
        # Try to extract host and optional port from a prefix like ssh://user@host:port/path
        host=$(echo "$WALG_SSH_PREFIX" | sed -n 's|ssh://[^@]*@\([^/:]*\).*|\1|p')
        port=$(echo "$WALG_SSH_PREFIX" | sed -n 's|ssh://[^@]*@[^:]*:\([0-9]\+\)/.*|\1|p')
        port=${port:-${SSH_PORT:-22}}
        if [ -n "$host" ]; then
            echo "Adding $host to known_hosts (port $port)"
            ssh-keyscan -p "$port" -t rsa,ecdsa,ed25519 "$host" >> /var/lib/postgresql/.ssh/known_hosts 2>/dev/null || true
            chmod 600 /var/lib/postgresql/.ssh/known_hosts || true
            chown postgres:postgres /var/lib/postgresql/.ssh/known_hosts || true
        fi
    fi

    echo "SSH key setup completed"
}

validate_walg_env() {
    echo "Validating wal-g environment..."

    # If using the built-in SSH server for tests, provide sensible defaults
    if [ "${ENABLE_SSH_SERVER:-0}" = "1" ]; then
        WALG_SSH_PREFIX="${WALG_SSH_PREFIX:-ssh://walg@ssh-server/backups}"
        SSH_PORT="${SSH_PORT:-2222}"
        export WALG_SSH_PREFIX SSH_PORT
        echo "INFO: ENABLE_SSH_SERVER=1 -> Using default WALG_SSH_PREFIX=$WALG_SSH_PREFIX SSH_PORT=$SSH_PORT"
    else
        if [ -z "${WALG_SSH_PREFIX:-}" ]; then
            echo "Error: WALG_SSH_PREFIX is required for wal-g SSH backend (ENABLE_SSH_SERVER!=1)"
            return 1
        fi
    fi

    if ! command -v wal-g &> /dev/null; then
        echo "Error: wal-g binary not found"
        return 1
    fi

    # Derive SSH_USERNAME and SSH_HOST from prefix if present (use bash regex for robustness)
    if [ -n "${WALG_SSH_PREFIX:-}" ]; then
        # Match ssh://user@host:port/path or ssh://user@host/path
        if [[ "$WALG_SSH_PREFIX" =~ ssh://([^@]+)@([^/:]+)(:([0-9]+))?(/.*)? ]]; then
            SSH_USERNAME="${BASH_REMATCH[1]}"
            SSH_HOST="${BASH_REMATCH[2]}"
            # If prefix includes port use it, otherwise keep existing SSH_PORT or default later
            if [ -n "${BASH_REMATCH[4]:-}" ]; then
                SSH_PORT="${BASH_REMATCH[4]}"
            fi
            export SSH_USERNAME SSH_HOST SSH_PORT
        fi
    fi

    # Write simplified wal-g env file
    cat > /var/lib/postgresql/.walg_env <<EOF
export PATH="/usr/local/bin:\$PATH"
export PGDATA="${PGDATA:-/var/lib/postgresql/data}"
export PGHOST="${PGHOST:-postgres}"
export PGPORT="${PGPORT:-5432}"
export PGUSER="${PGUSER:-${POSTGRES_USER:-postgres}}"
export PGPASSWORD="${PGPASSWORD:-${POSTGRES_PASSWORD:-postgres}}"
export PGDATABASE="${PGDATABASE:-postgres}"
export WALG_SSH_PREFIX="${WALG_SSH_PREFIX:-}"
export SSH_PRIVATE_KEY_PATH="${WALG_SSH_PRIVATE_KEY_PATH:-}"
export SSH_PORT="${SSH_PORT:-22}"
export SSH_USERNAME="${SSH_USERNAME:-}"
export SSH_HOST="${SSH_HOST:-}"
export WALG_COMPRESSION_METHOD="${WALG_COMPRESSION_METHOD:-lz4}"
export WALG_DELTA_MAX_STEPS="${WALG_DELTA_MAX_STEPS:-7}"
export WALG_DELTA_ORIGIN="${WALG_DELTA_ORIGIN:-LATEST}"
export WALG_LOG_LEVEL="${WALG_LOG_LEVEL:-DEVEL}"
EOF

    # Ensure postgres user will source this env file
    if ! grep -q "source /var/lib/postgresql/.walg_env" /var/lib/postgresql/.profile 2>/dev/null; then
        echo "source /var/lib/postgresql/.walg_env" >> /var/lib/postgresql/.profile
    fi

    chown postgres:postgres /var/lib/postgresql/.walg_env /var/lib/postgresql/.profile || true
    chmod 600 /var/lib/postgresql/.walg_env || true

    echo "wal-g environment validation passed"
    return 0
}

# Execute only when in WAL backup mode
if [ "${BACKUP_MODE:-}" = "wal" ]; then
    if ! prepare_ssh_key; then
        echo "Warning: prepare_ssh_key reported an issue (missing key?) continuing to validation" >&2
    fi
    validate_walg_env
fi