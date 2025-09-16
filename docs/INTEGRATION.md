# Enhanced WAL-G Testing with Local SSH Server Integration

This documentation shows how to use the integrated testing workflow that combines SSH server setup, Docker stack management, and comprehensive E2E testing.

## Quick Start

The integrated workflow has been streamlined into a single command:

```bash
# Run complete WAL-G E2E testing with automatic setup and cleanup
BACKUP_MODE=wal ./run-tests
```

This single command now performs all these steps automatically:

1. **Setup local SSH server**: Generates keys, configures .env
2. **Clean volumes**: Removes old postgres-data to prevent conflicts  
3. **Start stack**: Launches with `--profile ssh-testing`
4. **Run E2E tests**: Executes comprehensive WAL-G testing
5. **Cleanup**: Removes containers and volumes

## What's New

### 🔧 Enhanced `./run-tests` Script

The main test runner now integrates all required steps:

- **Automatic SSH Setup**: Calls `./scripts/setup-local-ssh.sh`
- **Volume Conflict Resolution**: Prevents "directory not empty" errors
- **Stack Management**: Uses `--profile ssh-testing` automatically
- **E2E Integration**: Runs `./test/test-walg-e2e.sh` with proper environment
- **Complete Cleanup**: Removes test containers and volumes

### 🚀 Enhanced E2E Testing

The `./test/test-walg-e2e.sh` script now includes:

- **FORCE_EMPTY_PGDATA Support**: Automatically cleans conflicting volumes
- **Extended Timeout**: PostgreSQL readiness timeout increased from 60s to 120s
- **Better Error Reporting**: Shows postgres logs when readiness fails
- **Comprehensive Testing**:
  - WAL-push functionality (archive_command)
  - Backup-push operations with remote verification  
  - Delete/retention policy with backup count verification
  - Recovery capability checks

### 🧹 Volume Conflict Prevention

Resolves the common issue: `initdb: error: directory "/var/lib/postgresql/data" exists but is not empty`

The integrated workflow:
1. Detects existing `postgres-data` volume
2. Safely removes it before starting tests
3. Ensures clean initialization environment

## Usage Examples

### Basic WAL-G Testing
```bash
# Complete automated testing workflow
BACKUP_MODE=wal ./run-tests
```

### Force Clean Start (if needed)
```bash
# Explicitly force volume cleanup
FORCE_EMPTY_PGDATA=1 BACKUP_MODE=wal ./run-tests
```

### Manual Step-by-Step (for debugging)
```bash
# Step 1: Setup SSH server and environment
./scripts/setup-local-ssh.sh

# Step 2: Start stack manually
docker compose --profile ssh-testing up --build -d

# Step 3: Run E2E tests manually  
./test/test-walg-e2e.sh

# Step 4: Cleanup manually
docker compose --profile ssh-testing down -v
```

### Direct E2E Testing (stack already running)
```bash
# Run just the E2E tests if stack is already up
./test/test-walg-e2e.sh
```

## What Gets Tested

The E2E tests verify real functionality against a local SSH server:

### 1. Archive Command (wal-push)
- ✅ Generates WAL activity with test data
- ✅ Verifies WAL files appear in remote storage  
- ✅ Confirms archive_command integration

### 2. Backup Operations (backup-push)
- ✅ Executes base backup creation
- ✅ Verifies new backups appear in `wal-g backup-list`
- ✅ Checks backup completion logs

### 3. Retention Management (delete)  
- ✅ Creates multiple backups for testing
- ✅ Runs cleanup/retention operations
- ✅ Verifies backup count respects `WALG_RETENTION_FULL`

### 4. Recovery Readiness
- ✅ Confirms backups are available for recovery
- ✅ Tests `wal-g backup-fetch` command availability

## Environment Configuration

The integration automatically configures `.env` for local testing:

```bash
BACKUP_MODE=wal
POSTGRES_DOCKERFILE=Dockerfile.postgres-walg
BACKUP_VOLUME_MODE=ro
ENABLE_SSH_SERVER=1
WALG_SSH_PREFIX=ssh://walg@ssh-server:2222/backups
SSH_KEY_PATH=./secrets/walg_ssh_key
SKIP_SSH_KEYSCAN=1
```

## Troubleshooting

### "Directory not empty" errors
The integration now prevents these automatically, but if you see them:
```bash
FORCE_EMPTY_PGDATA=1 BACKUP_MODE=wal ./run-tests
```

### PostgreSQL readiness timeouts
The timeout has been increased to 120s. For slower systems:
```bash
TEST_WAIT_TIMEOUT=180 BACKUP_MODE=wal ./run-tests
```

### Build failures
If Docker builds fail due to network issues, you can still test the integration logic:
```bash
./demo-integration.sh  # Shows what the integration would do
```

## Legacy Compatibility

The integration maintains backward compatibility:

```bash
# SQL mode testing (unchanged)
BACKUP_MODE=sql ./run-tests

# Default behavior (unchanged)  
./run-tests  # Defaults to SQL mode
```

## Files Modified

- `./run-tests`: Enhanced with integrated workflow
- `./test/test-walg-e2e.sh`: Added FORCE_EMPTY_PGDATA support and extended timeout
- `./docker-compose.yml`: Added BACKUP_DOCKERFILE variable support

## Summary

The integration solves the original problem statement by:

1. ✅ **Combining the three processes** into a unified workflow
2. ✅ **Preventing volume conflicts** through automatic cleanup  
3. ✅ **Using temporary containers** that are properly cleaned up
4. ✅ **Providing comprehensive E2E testing** with real remote verification

Users can now run the complete WAL-G testing pipeline with a single command, eliminating manual setup steps and volume conflicts.