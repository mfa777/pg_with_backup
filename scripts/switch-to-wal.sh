#!/bin/bash
# Helper script to switch to WAL-G backup mode

set -e

ENV_FILE=".env"

if [ ! -f "$ENV_FILE" ]; then
    echo "Error: .env file not found. Please copy env_sample to .env first."
    exit 1
fi

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