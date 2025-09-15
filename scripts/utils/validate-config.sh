#!/bin/bash
# Test script to validate configuration and backup mode setup

set -e

echo "PostgreSQL Backup Configuration Validator"
echo "=========================================="

# Check for .env file
if [ ! -f ".env" ]; then
    echo "❌ .env file not found. Please copy env_sample to .env first."
    exit 1
fi
echo "✅ .env file found"

# Source .env file
source .env

# Check BACKUP_MODE
if [ -z "$BACKUP_MODE" ]; then
    echo "❌ BACKUP_MODE not set in .env"
    exit 1
fi

echo "📋 Backup mode: $BACKUP_MODE"

# Validate SQL mode configuration
if [ "$BACKUP_MODE" = "sql" ]; then
    echo "🔍 Validating SQL mode configuration..."
    
    missing_vars=()
    [ -z "$RCLONE_CONFIG_BASE64" ] && missing_vars+=("RCLONE_CONFIG_BASE64")
    [ -z "$AGE_PUBLIC_KEY" ] && missing_vars+=("AGE_PUBLIC_KEY")
    [ -z "$REMOTE_PATH" ] && missing_vars+=("REMOTE_PATH")
    [ -z "$POSTGRES_USER" ] && missing_vars+=("POSTGRES_USER")
    [ -z "$POSTGRES_PASSWORD" ] && missing_vars+=("POSTGRES_PASSWORD")
    
    if [ ${#missing_vars[@]} -gt 0 ]; then
        echo "❌ Missing required SQL mode variables: ${missing_vars[*]}"
        exit 1
    fi
    
    echo "✅ SQL mode configuration looks good"
    echo "ℹ️  To start: docker compose up --build -d"

# Validate WAL mode configuration  
elif [ "$BACKUP_MODE" = "wal" ]; then
    echo "🔍 Validating WAL mode configuration..."
    
    missing_vars=()
    [ -z "$WALG_SSH_PREFIX" ] && missing_vars+=("WALG_SSH_PREFIX")
    [ -z "$POSTGRES_USER" ] && missing_vars+=("POSTGRES_USER")
    [ -z "$POSTGRES_PASSWORD" ] && missing_vars+=("POSTGRES_PASSWORD")
    
    if [ ${#missing_vars[@]} -gt 0 ]; then
        echo "❌ Missing required WAL mode variables: ${missing_vars[*]}"
        exit 1
    fi
    
    # Check SSH key configuration
    ssh_key_ok=false
    if [ -n "$WALG_SSH_PRIVATE_KEY" ]; then
        echo "✅ SSH private key configured via environment variable"
        ssh_key_ok=true
    elif [ -n "$SSH_KEY_PATH" ] && [ -f "$SSH_KEY_PATH" ]; then
        echo "✅ SSH private key file found: $SSH_KEY_PATH"
        ssh_key_ok=true
    elif [ -f "./secrets/walg_ssh_key" ]; then
        echo "✅ Default SSH key file found: ./secrets/walg_ssh_key"
        ssh_key_ok=true
    fi
    
    if [ "$ssh_key_ok" = "false" ]; then
        echo "⚠️  No SSH private key configured. You need either:"
        echo "   - WALG_SSH_PRIVATE_KEY (base64 encoded key content)"
        echo "   - SSH_KEY_PATH pointing to key file"
        echo "   - Key file at ./secrets/walg_ssh_key"
    fi
    
    # Check Dockerfile configuration
    if [ -z "$POSTGRES_DOCKERFILE" ] || [ "$POSTGRES_DOCKERFILE" != "Dockerfile.postgres-walg" ]; then
        echo "⚠️  POSTGRES_DOCKERFILE should be set to 'Dockerfile.postgres-walg' for WAL mode"
        echo "   Run: ./scripts/switch-to-wal.sh to fix this"
    fi
    
    echo "✅ WAL mode configuration looks good"
    echo "ℹ️  To start: docker compose up --build -d"
    echo "ℹ️  Monitor: docker compose logs backup -f"
    
else
    echo "❌ Invalid BACKUP_MODE '$BACKUP_MODE'. Must be 'sql' or 'wal'"
    exit 1
fi

# Check Docker Compose
echo "🔍 Validating Docker Compose configuration..."
if docker compose config --quiet 2>/dev/null; then
    echo "✅ Docker Compose configuration is valid"
else
    echo "❌ Docker Compose configuration has errors"
    exit 1
fi

echo ""
echo "🎉 Configuration validation completed successfully!"
echo "You can now start the services with: docker compose up --build -d"