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
        SSH_PORT=$(echo "$WALG_SSH_PREFIX" | sed -n 's|ssh://[^@]*@[^:]*:\([0-9]*\)/.*|\1|p')
        SSH_PORT=${SSH_PORT:-22}
        
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
    
    # Create environment file for postgres user
    cat > /var/lib/postgresql/.walg_env << EOF
export WALG_SSH_PREFIX="${WALG_SSH_PREFIX}"
export WALG_SSH_PRIVATE_KEY_PATH="${WALG_SSH_PRIVATE_KEY_PATH:-}"
export WALG_COMPRESSION_METHOD="${WALG_COMPRESSION_METHOD:-lz4}"
export WALG_DELTA_MAX_STEPS="${WALG_DELTA_MAX_STEPS:-7}"
export WALG_DELTA_ORIGIN="${WALG_DELTA_ORIGIN:-LATEST}"
export WALG_LOG_LEVEL="${WALG_LOG_LEVEL:-INFO}"
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
if [ "$BACKUP_MODE" = "wal" ]; then
    validate_walg_env
    prepare_ssh_key
fi