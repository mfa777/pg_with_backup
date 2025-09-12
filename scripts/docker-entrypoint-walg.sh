#!/bin/bash
set -eo pipefail

# Wrapper script for PostgreSQL entrypoint with wal-g support
# This script prepares the environment for wal-g when BACKUP_MODE=wal

echo "Starting PostgreSQL with wal-g support..."

# Source environment preparation script
if [ "$BACKUP_MODE" = "wal" ]; then
    echo "WAL-G mode enabled - preparing environment..."
    source /opt/walg/scripts/walg-env-prepare.sh
    
    # Ensure postgresql.conf has the right settings for wal-g
    if [ ! -f "$PGDATA/postgresql.conf" ] && [ -f "/etc/postgresql/postgresql.conf.template" ]; then
        echo "Copying postgresql.conf template for wal-g mode..."
        cp /etc/postgresql/postgresql.conf.template "$PGDATA/postgresql.conf"
        chown postgres:postgres "$PGDATA/postgresql.conf"
    fi
    
    echo "WAL-G environment prepared successfully"
else
    echo "Legacy SQL backup mode (wal-g not enabled)"
fi

# Check if wal-g is available
if command -v wal-g &> /dev/null; then
    echo "wal-g version: $(wal-g --version)"
fi

# Find and call the original PostgreSQL entrypoint
if [ -f "/usr/local/bin/docker-entrypoint.sh" ]; then
    exec /usr/local/bin/docker-entrypoint.sh "$@"
else
    # Fallback to postgres directly if entrypoint not found
    exec postgres "$@"
fi