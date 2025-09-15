#!/bin/bash
set -eo pipefail

# Environment preparation script for wal-g
# Handles SSH key setup and environment validation

prepare_ssh_key() {
    echo "Preparing SSH key for wal-g..."
    
    # Create .ssh directory if it doesn't exist
    mkdir -p /var/lib/postgresql/.ssh
    chown postgres:postgres /var/lib/postgresql/.ssh
    chmod 700 /var/lib/postgresql/.ssh
    
    # Handle SSH private key setup
    if [ -n "$WALG_SSH_PRIVATE_KEY" ]; then
        echo "Setting up SSH private key from environment variable..."
        echo "$WALG_SSH_PRIVATE_KEY" | base64 -d > /var/lib/postgresql/.ssh/walg_key
        chmod 600 /var/lib/postgresql/.ssh/walg_key
        chown postgres:postgres /var/lib/postgresql/.ssh/walg_key
        export WALG_SSH_PRIVATE_KEY_PATH="/var/lib/postgresql/.ssh/walg_key"
    elif [ -n "$WALG_SSH_PRIVATE_KEY_PATH" ] && [ -f "$WALG_SSH_PRIVATE_KEY_PATH" ]; then
        echo "Using SSH private key from path: $WALG_SSH_PRIVATE_KEY_PATH"
        # Attempt to set secure permissions on the mounted key. If the mount is read-only
        # (common when mounting secrets), chmod/chown will fail — in that case copy the
        # key into the container's writable .ssh directory and use the copy.
        if chmod 600 "$WALG_SSH_PRIVATE_KEY_PATH" 2>/dev/null && chown postgres:postgres "$WALG_SSH_PRIVATE_KEY_PATH" 2>/dev/null; then
            :
        else
            echo "Mounted key appears read-only; copying key into container writable location"
            cp "$WALG_SSH_PRIVATE_KEY_PATH" /var/lib/postgresql/.ssh/walg_key
            chmod 600 /var/lib/postgresql/.ssh/walg_key
            chown postgres:postgres /var/lib/postgresql/.ssh/walg_key
            export WALG_SSH_PRIVATE_KEY_PATH="/var/lib/postgresql/.ssh/walg_key"
        fi
    else
        echo "Warning: No SSH private key configured for wal-g"
        return 1
    fi

    # Ensure the SSH client (used by tests) can find a default key without -i.
    # Some test helpers call `ssh` as the postgres user without passing -i, so
    # provide a default id_rsa in the postgres .ssh directory that points to the
    # prepared key (copy it to keep permissions writable by postgres).
    if [ -n "$WALG_SSH_PRIVATE_KEY_PATH" ] && [ -f "$WALG_SSH_PRIVATE_KEY_PATH" ]; then
        if [ "$(realpath "$WALG_SSH_PRIVATE_KEY_PATH")" != "/var/lib/postgresql/.ssh/id_rsa" ]; then
            cp "$WALG_SSH_PRIVATE_KEY_PATH" /var/lib/postgresql/.ssh/id_rsa
            chmod 600 /var/lib/postgresql/.ssh/id_rsa
            chown postgres:postgres /var/lib/postgresql/.ssh/id_rsa
        fi
    fi
    
    # Extract hostname from WALG_SSH_PREFIX for known_hosts
    if [ -n "$WALG_SSH_PREFIX" ]; then
        SSH_HOST=$(echo "$WALG_SSH_PREFIX" | sed -n 's|ssh://[^@]*@\([^:]*\):.*|\1|p')
        _prefix_port=$(echo "$WALG_SSH_PREFIX" | sed -n 's|ssh://[^@]*@[^:]*:\([0-9]*\)/.*|\1|p')
        if [ -n "$_prefix_port" ]; then
            SSH_PORT="$_prefix_port"
        elif [ -z "${SSH_PORT:-}" ]; then
            SSH_PORT=22
        fi
        
        if [ -n "$SSH_HOST" ]; then
            echo "Adding $SSH_HOST to known_hosts..."
            if [[ "${SKIP_SSH_KEYSCAN:-0}" == "1" ]]; then
                echo "SKIP_SSH_KEYSCAN=1: skipping ssh-keyscan"
            else
                ssh-keyscan -p "$SSH_PORT" -t rsa,ecdsa,ed25519 "$SSH_HOST" >> /var/lib/postgresql/.ssh/known_hosts 2>/dev/null || true
                chmod 600 /var/lib/postgresql/.ssh/known_hosts
                chown postgres:postgres /var/lib/postgresql/.ssh/known_hosts
            fi
        fi
    fi
    
    echo "SSH key setup completed"
}

validate_walg_env() {
    echo "Validating wal-g environment..."
    
    # Check required environment variables
    if [ -z "$WALG_SSH_PREFIX" ]; then
        echo "Error: WALG_SSH_PREFIX is required for wal-g SSH backend"
        return 1
    fi
    
    # Check wal-g binary
    if ! command -v wal-g &> /dev/null; then
        echo "Error: wal-g binary not found"
        return 1
    fi
    
    # Ensure environment variables are available to postgres user
    echo "Setting up wal-g environment for postgres user..."
    
    # Derive SSH specifics for wal-g (flags expect SSH_* env vars)
    # Extract username if not explicitly provided
    if [ -n "$WALG_SSH_PREFIX" ]; then
        # Example prefix: ssh://user@host:port/path
        _auth_part=$(echo "$WALG_SSH_PREFIX" | sed -n 's|ssh://\([^/]*\)/.*|\1|p')
        _user_part=$(echo "$_auth_part" | sed -n 's|^\([^@]*\)@.*|\1|p')
        if [ -n "$_user_part" ] && [ "$_user_part" != "$WALG_SSH_PREFIX" ]; then
            export SSH_USERNAME="$_user_part"
        fi
        # Extract port if present
        _port_part=$(echo "$_auth_part" | sed -n 's|.*:\([0-9][0-9]*\)$|\1|p')
        # Port selection precedence:
        # 1. Explicit port in WALG_SSH_PREFIX
        # 2. Pre-set SSH_PORT environment variable (from docker-compose or .env)
        # 3. Legacy WALG_SSH_PORT variable (still honored if provided)
        # 4. Default 22
        if [ -n "$_port_part" ]; then
            SSH_PORT="$_port_part"
        elif [ -n "${SSH_PORT:-}" ]; then
            : # keep existing value
        elif [ -n "${WALG_SSH_PORT:-}" ]; then
            SSH_PORT="$WALG_SSH_PORT"
        else
            SSH_PORT="22"
        fi
        export SSH_PORT
    fi

    # Provide private key path under both variable names
    if [ -n "${WALG_SSH_PRIVATE_KEY_PATH:-}" ]; then
        export SSH_PRIVATE_KEY_PATH="$WALG_SSH_PRIVATE_KEY_PATH"
    fi

    # Create environment file for postgres user
    cat > /var/lib/postgresql/.walg_env << EOF
export PATH="/usr/local/bin:\$PATH"
export PGDATA="${PGDATA:-/var/lib/postgresql/data}"
export PGHOST="${PGHOST:-postgres}"
export PGPORT="${PGPORT:-5432}"
export PGUSER="${PGUSER:-${POSTGRES_USER:-postgres}}"
export PGPASSWORD="${PGPASSWORD:-${POSTGRES_PASSWORD:-postgres}}"
export PGDATABASE="${PGDATABASE:-postgres}"
export WALG_SSH_PREFIX="${WALG_SSH_PREFIX}"
export WALG_SSH_PRIVATE_KEY_PATH="${WALG_SSH_PRIVATE_KEY_PATH:-}"
export SSH_PRIVATE_KEY_PATH="${SSH_PRIVATE_KEY_PATH:-}"
export SSH_PORT="${SSH_PORT:-22}"
export SSH_USERNAME="${SSH_USERNAME:-}"
export WALE_SSH_PREFIX="${WALG_SSH_PREFIX}"  # backward compatibility for any tooling expecting WALE_ prefix
export WALG_COMPRESSION_METHOD="${WALG_COMPRESSION_METHOD:-lz4}"
export WALG_DELTA_MAX_STEPS="${WALG_DELTA_MAX_STEPS:-7}"
export WALG_DELTA_ORIGIN="${WALG_DELTA_ORIGIN:-LATEST}"
export WALG_LOG_LEVEL="${WALG_LOG_LEVEL:-DEVEL}"
EOF
    
    # Source wal-g environment in postgres user's profile
    if ! grep -q "source /var/lib/postgresql/.walg_env" /var/lib/postgresql/.profile 2>/dev/null; then
        echo "source /var/lib/postgresql/.walg_env" >> /var/lib/postgresql/.profile
    fi
    
    chown postgres:postgres /var/lib/postgresql/.walg_env /var/lib/postgresql/.profile
    chmod 600 /var/lib/postgresql/.walg_env
    
    echo "wal-g environment validation passed"
    return 0
}

# Main execution
# NOTE: Order matters. We must prepare the SSH key BEFORE writing the .walg_env file
# so that WALG_SSH_PRIVATE_KEY_PATH is populated correctly when postgres sources it
# inside archive_command. Previously validate_walg_env ran first, producing an env
# file with an empty/incorrect WALG_SSH_PRIVATE_KEY_PATH causing wal-g wal-push to
# fail (exit code 1) during archive_command execution.
if [ "$BACKUP_MODE" = "wal" ]; then
    # Prepare key first; ignore failure here so validate can report meaningful error
    if ! prepare_ssh_key; then
        echo "Warning: prepare_ssh_key reported an issue (missing key?) continuing to validation" >&2
    fi
    # Now write env file with the (possibly updated) WALG_SSH_PRIVATE_KEY_PATH
    validate_walg_env
fi