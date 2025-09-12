#!/bin/bash
# Helper script to switch to SQL backup mode (legacy/default)

set -e

ENV_FILE=".env"

if [ ! -f "$ENV_FILE" ]; then
    echo "Error: .env file not found. Please copy env_sample to .env first."
    exit 1
fi

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