#!/usr/bin/env bash
# Simple script to help configure .env for different backup modes
# Usage: ./configure-env.sh [sql|wal]

set -euo pipefail

MODE="${1:-}"
ENV_FILE=".env"

show_usage() {
    echo "Usage: $0 [sql|wal]"
    echo ""
    echo "Configure .env file for backup mode:"
    echo "  sql - PostgreSQL dump backups (default)"
    echo "  wal - WAL-G incremental backups"
    echo ""
    echo "After running this script, run: docker compose up --build -d"
    exit 1
}

if [[ -z "$MODE" ]]; then
    show_usage
fi

case "$MODE" in
    sql)
        echo "Configuring for SQL backup mode..."
        cat > "$ENV_FILE" << 'EOF'
# PostgreSQL backup configuration - SQL mode
BACKUP_MODE=sql
POSTGRES_USER=postgres
POSTGRES_PASSWORD=test_password
POSTGRES_IMAGE=postgres:17

# General settings
TZ=UTC
PGADMIN_DEFAULT_EMAIL=admin@admin.com
PGADMIN_DEFAULT_PASSWORD=admin
ENABLE_SSH_SERVER=0
EOF
        echo "✅ Configured .env for SQL mode"
        echo "Run: docker compose up --build -d"
        ;;
    wal)
        echo "Configuring for WAL backup mode..."
        cat > "$ENV_FILE" << 'EOF'
# PostgreSQL backup configuration - WAL mode
BACKUP_MODE=wal
POSTGRES_USER=postgres
POSTGRES_PASSWORD=test_password
POSTGRES_DOCKERFILE=Dockerfile.postgres-walg

# WAL-G configuration (configure these for production)
WALG_SSH_PREFIX=ssh://walg@backup-host:22/var/backups/pg
WALG_SSH_PRIVATE_KEY_PATH=/secrets/walg_ssh_key
SSH_KEY_PATH=./secrets/walg_ssh_key

# General settings
TZ=UTC
PGLADMIN_DEFAULT_EMAIL=admin@admin.com
PGADMIN_DEFAULT_PASSWORD=admin
ENABLE_SSH_SERVER=0
EOF
        echo "✅ Configured .env for WAL mode"
        echo "For testing with local SSH server, run: ./scripts/setup-local-ssh.sh"
        echo "Then run: docker compose -f docker-compose.yml -f docker-compose.wal.yml up --build -d"
        ;;
    *)
        echo "Error: Unknown mode '$MODE'"
        show_usage
        ;;
esac