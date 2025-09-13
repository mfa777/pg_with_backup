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
    # Set up a post-init hook to apply configuration after database initialization
    echo "Setting up post-init hook for WAL-G configuration..."
    
    # Create a script that will apply the configuration after initialization
    cat > /docker-entrypoint-initdb.d/99-apply-walg-config.sh << 'EOF'
#!/bin/bash
echo "Post-init: Applying WAL-G postgresql.conf configuration..."
if [ -f "/etc/postgresql/postgresql.conf.template" ]; then
    # Apply the WAL-G configuration template
    cp /etc/postgresql/postgresql.conf.template "$PGDATA/postgresql.conf"
    chown postgres:postgres "$PGDATA/postgresql.conf"
    echo "WAL-G configuration template applied successfully"
    
    # Signal PostgreSQL to reload configuration
    pg_ctl reload -D "$PGDATA" || echo "Note: pg_ctl reload failed, configuration will apply on next restart"
else
    echo "Warning: WAL-G configuration template not found"
fi
EOF
    chmod +x /docker-entrypoint-initdb.d/99-apply-walg-config.sh
fi

# Find and call the original PostgreSQL entrypoint
if [ -f "/usr/local/bin/docker-entrypoint.sh" ]; then
    exec /usr/local/bin/docker-entrypoint.sh "$@"
else
    # Fallback to postgres directly if entrypoint not found
    exec postgres "$@"
fi