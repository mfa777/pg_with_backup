#!/bin/bash
# Unified script to switch between SQL and WAL backup modes

set -e

ENV_FILE=".env"

show_usage() {
    cat << EOF
Usage: $0 [sql|wal]

Switch between backup modes:
  sql  - Switch to SQL backup mode (pg_dumpall + encryption)
  wal  - Switch to WAL-G backup mode (incremental backups)

Examples:
  $0 sql   # Switch to SQL mode
  $0 wal   # Switch to WAL-G mode
EOF
}

switch_to_sql() {
    echo "Switching to SQL backup mode (legacy)..."
    
    # Update .env file for SQL mode
    sed -i 's/^BACKUP_MODE=.*/BACKUP_MODE=sql/' "$ENV_FILE"
    
    # Remove wal-mode specific variables or comment them out
    sed -i 's/^POSTGRES_DOCKERFILE=/#POSTGRES_DOCKERFILE=/' "$ENV_FILE"
    sed -i 's/^BACKUP_VOLUME_MODE=/#BACKUP_VOLUME_MODE=/' "$ENV_FILE"
    
    echo "✓ Updated .env file for SQL mode"
    echo ""
    echo "Before starting, please ensure you have:"
    echo "1. Configured RCLONE_CONFIG_BASE64 with your rclone configuration"
    echo "2. Set up AGE_PUBLIC_KEY for encryption"
    echo "3. Set REMOTE_PATH for your backup destination"
    echo ""
    echo "To start: docker compose up --build -d" 
    echo "To monitor: docker compose logs -f backup"
}

switch_to_wal() {
    echo "Switching to WAL-G backup mode..."
    
    # Update .env file for WAL mode
    sed -i 's/^BACKUP_MODE=.*/BACKUP_MODE=wal/' "$ENV_FILE"
    
    # Add wal-mode specific variables if not present
    grep -q "^POSTGRES_DOCKERFILE=" "$ENV_FILE" || echo "POSTGRES_DOCKERFILE=Dockerfile.postgres-walg" >> "$ENV_FILE"
    grep -q "^BACKUP_VOLUME_MODE=" "$ENV_FILE" || echo "BACKUP_VOLUME_MODE=ro" >> "$ENV_FILE"
    
    # Update existing variables  
    sed -i 's/^POSTGRES_DOCKERFILE=.*/POSTGRES_DOCKERFILE=Dockerfile.postgres-walg/' "$ENV_FILE"
    sed -i 's/^BACKUP_VOLUME_MODE=.*/BACKUP_VOLUME_MODE=ro/' "$ENV_FILE"
    
    echo "✓ Updated .env file for WAL-G mode"
    echo ""
    echo "Before starting, please ensure you have:"
    echo "1. Configured WALG_SSH_PREFIX with your SSH backup server"
    echo "2. Set up WALG_SSH_PRIVATE_KEY or SSH key file"
    echo "3. Tested SSH connectivity to your backup server"
    echo ""
    echo "To start: docker compose up --build -d"
    echo "To monitor: docker compose logs -f backup"
}

# Main script logic
if [ ! -f "$ENV_FILE" ]; then
    echo "Error: .env file not found. Please copy env_sample to .env first."
    exit 1
fi

case "${1:-}" in
    sql)
        switch_to_sql
        ;;
    wal)
        switch_to_wal
        ;;
    -h|--help|help)
        show_usage
        ;;
    "")
        echo "Error: Mode not specified."
        echo ""
        show_usage
        exit 1
        ;;
    *)
        echo "Error: Invalid mode '$1'"
        echo ""
        show_usage
        exit 1
        ;;
esac