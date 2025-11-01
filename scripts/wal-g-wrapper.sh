#!/bin/bash
# WAL-G wrapper script to ensure environment variables are always loaded
# This script sources the WAL-G environment file before executing wal-g commands

# Configuration
WALG_ENV_FILE="/var/lib/postgresql/.walg_env"
WALG_BIN="/usr/local/bin/wal-g.bin"

# Source the WAL-G environment if it exists
if [ -f "$WALG_ENV_FILE" ]; then
    source "$WALG_ENV_FILE"
fi

# Execute the actual wal-g binary with all arguments
# Check if binary exists before executing
if [ -f "$WALG_BIN" ]; then
    exec "$WALG_BIN" "$@"
else
    echo "ERROR: wal-g binary not found at $WALG_BIN" >&2
    exit 1
fi
