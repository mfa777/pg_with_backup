#!/bin/bash
# WAL-G wrapper script to ensure environment variables are always loaded
# This script sources the WAL-G environment file before executing wal-g commands

# Source the WAL-G environment if it exists
if [ -f "/var/lib/postgresql/.walg_env" ]; then
    source "/var/lib/postgresql/.walg_env"
fi

# Execute the actual wal-g binary with all arguments
exec /usr/local/bin/wal-g.bin "$@"
