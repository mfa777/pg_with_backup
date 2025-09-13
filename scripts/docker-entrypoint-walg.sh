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
    # We need to apply wal-g settings after PostgreSQL initializes
    # Set up a hook to apply the config after initdb but before postgres starts
    if [ -f "/etc/postgresql/postgresql.conf.template" ]; then
        export POSTGRES_INITDB_WALDIR_HOOK="true"
        echo "WAL-G postgresql.conf template will be applied after initdb"
    fi
    
    echo "WAL-G environment prepared successfully"
else
    echo "Legacy SQL backup mode (wal-g not enabled)"
fi

# Check if wal-g is available
if command -v wal-g &> /dev/null; then
    echo "wal-g version: $(wal-g --version)"
fi

# Create a wrapper script for postgres command that applies our config
if [ "$1" = 'postgres' ] && [ "$BACKUP_MODE" = "wal" ]; then
    # Apply wal-g configuration before starting postgres
    if [ -f "/etc/postgresql/postgresql.conf.template" ] && [ -f "$PGDATA/PG_VERSION" ]; then
        echo "Applying WAL-G postgresql.conf configuration..."
        # Backup original if it exists
        if [ -f "$PGDATA/postgresql.conf" ]; then
            cp "$PGDATA/postgresql.conf" "$PGDATA/postgresql.conf.backup.$(date +%s)"
        fi
        # Apply our template
        cp /etc/postgresql/postgresql.conf.template "$PGDATA/postgresql.conf"
        chown postgres:postgres "$PGDATA/postgresql.conf"
        echo "WAL-G configuration applied successfully"
    fi
fi

# Find and call the original PostgreSQL entrypoint
if [ -f "/usr/local/bin/docker-entrypoint.sh" ]; then
    exec /usr/local/bin/docker-entrypoint.sh "$@"
else
    # Fallback to postgres directly if entrypoint not found
    exec postgres "$@"
fi