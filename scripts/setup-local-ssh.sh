#!/bin/bash
# Setup script for local SSH server testing
# This script prepares SSH keys and enables local SSH server for wal-g testing

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
SSH_KEY_DIR="$SCRIPT_DIR/secrets/walg_ssh_key"

echof() { echo "== $* =="; }
pass() { echo "PASS: $*"; }
die() { echo "FAIL: $*" >&2; exit 1; }

# Check if .env file exists
if [[ ! -f "$ENV_FILE" ]]; then
    echof "Creating .env file from template"
    cp "$SCRIPT_DIR/env_sample" "$ENV_FILE"
    pass ".env file created from env_sample"
fi

# Create SSH key directory
mkdir -p "$SSH_KEY_DIR"

# Generate SSH key pair if it doesn't exist
if [[ ! -f "$SSH_KEY_DIR/id_rsa" ]]; then
    echof "Generating SSH key pair for wal-g testing"
    ssh-keygen -t rsa -b 2048 -f "$SSH_KEY_DIR/id_rsa" -N "" -C "walg-testing@localhost"
    chmod 600 "$SSH_KEY_DIR/id_rsa"
    chmod 644 "$SSH_KEY_DIR/id_rsa.pub"
    pass "SSH key pair generated: $SSH_KEY_DIR/id_rsa"
else
    pass "SSH key pair already exists: $SSH_KEY_DIR/id_rsa"
fi

# Update .env file for local SSH testing
echof "Updating .env file for local SSH server testing"

# Enable SSH server
sed -i 's/^ENABLE_SSH_SERVER=.*/ENABLE_SSH_SERVER=1/' "$ENV_FILE" || echo "ENABLE_SSH_SERVER=1" >> "$ENV_FILE"

# Set WAL mode 
sed -i 's/^BACKUP_MODE=.*/BACKUP_MODE=wal/' "$ENV_FILE"

# Set Postgres dockerfile for wal-g
sed -i 's/^POSTGRES_DOCKERFILE=.*/POSTGRES_DOCKERFILE=Dockerfile.postgres-walg/' "$ENV_FILE" || echo "POSTGRES_DOCKERFILE=Dockerfile.postgres-walg" >> "$ENV_FILE"

# Set backup volume mode to read-only
sed -i 's/^BACKUP_VOLUME_MODE=.*/BACKUP_VOLUME_MODE=ro/' "$ENV_FILE" || echo "BACKUP_VOLUME_MODE=ro" >> "$ENV_FILE"

# Configure SSH prefix for local server (omit port; we set SSH_PORT separately so wal-g picks up non-default port)
sed -i 's|^WALG_SSH_PREFIX=.*|WALG_SSH_PREFIX=ssh://walg@ssh-server/backups|' "$ENV_FILE"

# Explicit SSH port variable (wal-g expects SSH_PORT)
if grep -q '^SSH_PORT=' "$ENV_FILE"; then
    sed -i 's|^SSH_PORT=.*|SSH_PORT=2222|' "$ENV_FILE"
else
    echo 'SSH_PORT=2222' >> "$ENV_FILE"
fi

# Set SSH key path
sed -i "s|^SSH_KEY_PATH=.*|SSH_KEY_PATH=$SSH_KEY_DIR|" "$ENV_FILE"

# Skip SSH keyscan for local testing
sed -i 's/^SKIP_SSH_KEYSCAN=.*/SKIP_SSH_KEYSCAN=1/' "$ENV_FILE" || echo "SKIP_SSH_KEYSCAN=1" >> "$ENV_FILE"

# Encode SSH private key as base64 for environment variable
SSH_PRIVATE_KEY_B64=$(base64 -w0 < "$SSH_KEY_DIR/id_rsa")
sed -i "s|^WALG_SSH_PRIVATE_KEY=.*|WALG_SSH_PRIVATE_KEY=$SSH_PRIVATE_KEY_B64|" "$ENV_FILE"

pass "Updated .env file for local SSH server testing"

echof "Setup complete!"
echo ""
echo "Next steps:"
echo "1. Start the stack with SSH server: docker compose --profile ssh-testing up --build -d"
echo "2. Run E2E tests: ./test/test-walg-e2e.sh"
echo "3. Monitor logs: docker compose logs -f postgres backup ssh-server"
echo ""
echo "To reset: docker compose --profile ssh-testing down -v"