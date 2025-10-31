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
    # Create a robust configuration setup that works regardless of initialization state
    if [ -f "$PGDATA/PG_VERSION" ]; then
        # Database already initialized - apply configuration immediately
        if [ -f "/etc/postgresql/postgresql.conf.template" ]; then
            echo "Database already initialized; applying WAL-G postgresql.conf template..."
            cp /etc/postgresql/postgresql.conf.template "$PGDATA/postgresql.conf"
            chown postgres:postgres "$PGDATA/postgresql.conf"
            echo "WAL-G configuration applied to existing database"
        fi
    else
        echo "PGDATA not initialized yet; setting up post-init configuration application"
        # Ensure the initdb hook directory exists
        mkdir -p /docker-entrypoint-initdb.d
        
        # Create a more robust post-init script
        cat > /docker-entrypoint-initdb.d/99-apply-walg-config.sh << 'EOF'
#!/bin/bash
echo "Post-init: Applying WAL-G postgresql.conf configuration..."
if [ -f "/etc/postgresql/postgresql.conf.template" ]; then
    # Apply the WAL-G configuration template
    cp /etc/postgresql/postgresql.conf.template "$PGDATA/postgresql.conf"
    chown postgres:postgres "$PGDATA/postgresql.conf"
    echo "WAL-G configuration template applied successfully"
    
    # Ensure WAL archiving settings are correct
    echo "Verifying WAL-G configuration..."
    grep -E "(archive_mode|archive_command|wal_level)" "$PGDATA/postgresql.conf" || echo "Warning: Some WAL-G settings may be missing"
else
    echo "Warning: WAL-G configuration template not found at /etc/postgresql/postgresql.conf.template"
fi
EOF
        chmod +x /docker-entrypoint-initdb.d/99-apply-walg-config.sh
        echo "Post-init WAL-G configuration script created"
    fi
    
    echo "WAL-G environment prepared successfully"
else
    echo "Legacy SQL backup mode (wal-g not enabled)"
fi

# Check if wal-g is available
if command -v wal-g &> /dev/null; then
    echo "wal-g version: $(wal-g --version)"
fi

# Setup PgBouncer if enabled
if [ "$ENABLE_PGBOUNCER" = "1" ]; then
    echo "PgBouncer is enabled, setting up configuration..."
    /opt/scripts/setup-pgbouncer.sh
    
    # Create a background process to start PgBouncer after PostgreSQL is ready
    (
        echo "Waiting for PostgreSQL to be ready before starting PgBouncer..."
        # Wait for PostgreSQL to be ready
        for i in {1..30}; do
            if pg_isready -h 127.0.0.1 -p 5432 -U "${POSTGRES_USER:-postgres}" &>/dev/null; then
                echo "PostgreSQL is ready, starting PgBouncer..."
                su - postgres -c "pgbouncer -d /etc/pgbouncer/pgbouncer.ini"
                echo "PgBouncer started successfully on port ${PGBOUNCER_PORT:-6432}"
                break
            fi
            echo "Waiting for PostgreSQL... ($i/30)"
            sleep 2
        done
    ) &
fi

# Find and call the original PostgreSQL entrypoint
if [ -f "/usr/local/bin/docker-entrypoint.sh" ]; then
    exec /usr/local/bin/docker-entrypoint.sh "$@"
else
    # Fallback to postgres directly if entrypoint not found
    exec postgres "$@"
fi