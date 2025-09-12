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
        chmod 600 "$WALG_SSH_PRIVATE_KEY_PATH"
        chown postgres:postgres "$WALG_SSH_PRIVATE_KEY_PATH"
    else
        echo "Warning: No SSH private key configured for wal-g"
        return 1
    fi
    
    # Extract hostname from WALG_SSH_PREFIX for known_hosts
    if [ -n "$WALG_SSH_PREFIX" ]; then
        SSH_HOST=$(echo "$WALG_SSH_PREFIX" | sed -n 's|ssh://[^@]*@\([^:]*\):.*|\1|p')
        SSH_PORT=$(echo "$WALG_SSH_PREFIX" | sed -n 's|ssh://[^@]*@[^:]*:\([0-9]*\)/.*|\1|p')
        SSH_PORT=${SSH_PORT:-22}
        
        if [ -n "$SSH_HOST" ]; then
            echo "Adding $SSH_HOST to known_hosts..."
            ssh-keyscan -p "$SSH_PORT" -t rsa,ecdsa,ed25519 "$SSH_HOST" >> /var/lib/postgresql/.ssh/known_hosts 2>/dev/null || true
            chmod 600 /var/lib/postgresql/.ssh/known_hosts
            chown postgres:postgres /var/lib/postgresql/.ssh/known_hosts
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
    
    echo "wal-g environment validation passed"
    return 0
}

# Main execution
if [ "$BACKUP_MODE" = "wal" ]; then
    validate_walg_env
    prepare_ssh_key
fi