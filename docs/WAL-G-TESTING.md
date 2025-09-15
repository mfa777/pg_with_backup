# WAL-G End-to-End Testing Guide

This document describes the comprehensive testing infrastructure for WAL-G backup operations, including both offline testing and real SSH server testing.

## Overview

The WAL-G testing infrastructure provides:

1. **Real end-to-end testing** with a local SSH server
2. **Offline testing** using mock wal-g for environments with network limitations
3. **Comprehensive validation** of wal-push, backup-push, and delete operations
4. **Remote storage verification** to ensure operations actually work

## Quick Start

### Option 1: Full E2E Testing with Local SSH Server

```bash
# Setup local SSH server and configure environment
./scripts/setup/setup-local-ssh.sh

# Start the stack with SSH server
docker compose --profile ssh-testing up --build -d

# Run comprehensive E2E tests
./test/test-walg-e2e.sh

# Monitor logs
docker compose logs -f postgres backup ssh-server
```

### Option 2: Offline Testing (Network-Limited Environments)

```bash
# Run offline tests with mock wal-g
./test/test-offline-e2e.sh
```

## Architecture

### Local SSH Server Setup

The infrastructure includes a local SSH server that provides:

- **Isolated testing environment** - no external dependencies
- **Real SSH authentication** using generated key pairs  
- **Persistent storage** for backup verification
- **Network isolation** - runs in the same Docker network

### Components

1. **SSH Server Container** (`linuxserver/openssh-server`)
   - Provides SFTP/SSH access for wal-g
   - Configured with generated SSH keys
   - Mounted backup storage volume

2. **Enhanced docker-compose.yml**
   - Added `ssh-server` service with profile `ssh-testing`
   - Configured networks and volumes for testing
   - Proper service dependencies

3. **Setup Script** (`scripts/setup/setup-local-ssh.sh`)
   - Generates SSH key pairs automatically
   - Configures `.env` file for local testing
   - Sets up proper permissions and authentication

4. **E2E Test Scripts**
   - `test/test-walg-e2e.sh` - Real SSH server testing
   - `test/test-offline-e2e.sh` - Mock testing for limited environments

## Test Coverage

### Archive Command Testing (`wal-push`)

**What it tests:**
- WAL file archiving through PostgreSQL `archive_command`
- Remote storage state verification
- Archive command execution and logging

**How it works:**
1. Generates database activity to trigger WAL switches
2. Monitors archive command execution in PostgreSQL logs
3. Verifies WAL files appear in remote storage
4. Validates compression and storage format

### Backup Operations Testing (`backup-push`)

**What it tests:**
- Base backup creation and storage
- Backup metadata and listing
- Delta backup capabilities
- Backup completion verification

**How it works:**
1. Executes backup-push from backup container
2. Verifies new backups appear in backup-list
3. Checks backup logs for completion status
4. Validates backup metadata and sizing

### Retention Testing (`delete`)

**What it tests:**
- Backup retention policy enforcement
- Old backup cleanup
- Retention setting compliance
- Data preservation safeguards

**How it works:**
1. Creates multiple backups exceeding retention limits
2. Executes retention cleanup
3. Verifies old backups are removed
4. Confirms retention policy compliance
5. Ensures at least one backup is always preserved

## Configuration

### Environment Variables

```bash
# Enable local SSH server for testing
ENABLE_SSH_SERVER=1

# SSH server configuration
SSH_USER=walg
WALG_SSH_PREFIX=ssh://walg@ssh-server:2222/backups

# WAL-G configuration
WALG_RETENTION_FULL=3
WALG_COMPRESSION_METHOD=lz4
SKIP_SSH_KEYSCAN=1  # For local testing
```

### Docker Compose Profiles

Use profiles to control which services run:

```bash
# Run with SSH server for testing
docker compose --profile ssh-testing up -d

# Run without SSH server (production)
docker compose up -d
```

## Host Machine Cron Setup

For production deployment on the host machine instead of container cron:

### Example Host Crontab

```bash
# Daily base backup at 1:30 AM
30 1 * * * docker exec backup /opt/walg/scripts/wal-g-runner.sh backup

# Daily cleanup at 3:15 AM  
15 3 * * * docker exec backup /opt/walg/scripts/wal-g-runner.sh clean

# Weekly full backup (force full, not delta)
0 2 * * 0 FORCE_FULL=1 docker exec backup /opt/walg/scripts/wal-g-runner.sh backup
```

### Setup Instructions

1. **Install on host:**
   ```bash
   crontab -e
   # Add the cron entries above
   ```

2. **Disable container cron:**
   ```bash
   # In .env file, remove or comment out:
   # WALG_BASEBACKUP_CRON=""
   # WALG_CLEAN_CRON=""
   ```

3. **Verify host cron:**
   ```bash
   crontab -l
   # Check logs
   tail -f /var/log/cron
   ```

## Troubleshooting

### Common Issues

1. **SSH Connection Failures**
   ```bash
   # Check SSH server logs
   docker logs ssh-server
   
   # Test SSH connectivity
   docker exec postgres ssh -o StrictHostKeyChecking=no walg@ssh-server 'echo "SSH OK"'
   ```

2. **WAL Archiving Issues**
   ```bash
   # Check PostgreSQL logs
   docker logs postgres | grep archive
   
   # Check archive_command setting
   docker exec postgres psql -U postgres -c "SHOW archive_command;"
   ```

3. **Backup Failures**
   ```bash
   # Check backup logs
   docker exec backup ls -la /var/lib/postgresql/data/walg_logs/
   docker exec backup cat /var/lib/postgresql/data/walg_logs/backup_*.log
   
   # Check wal-g environment
   docker exec postgres env | grep WALG
   ```

### Network Connectivity Issues

If you encounter network issues during docker builds:

1. **Use offline testing:**
   ```bash
   ./test/test-offline-e2e.sh
   ```

2. **Pre-pull images:**
   ```bash
   docker pull linuxserver/openssh-server:latest
   docker pull dpage/pgadmin4:latest
   ```

3. **Use cached builds:**
   ```bash
   docker compose build --no-cache
   ```

## Security Considerations

### SSH Key Management

- SSH keys are generated locally for testing
- Private keys have proper permissions (600)
- Keys are mounted read-only in containers
- Test keys should not be used in production

### Production Deployment

- Generate production SSH keys separately
- Use secure key distribution methods
- Enable SSH host key verification
- Use restrictive SSH server configurations
- Regular key rotation policies

## Integration with CI/CD

### GitHub Actions Example

```yaml
name: WAL-G E2E Tests
on: [push, pull_request]

jobs:
  test-walg:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      - name: Setup WAL-G testing
        run: ./scripts/setup/setup-local-ssh.sh
        
      - name: Run offline tests
        run: ./test/test-offline-e2e.sh
        
      - name: Start test environment
        run: docker compose --profile ssh-testing up --build -d
        
      - name: Run E2E tests
        run: ./test/test-walg-e2e.sh
        
      - name: Cleanup
        run: docker compose --profile ssh-testing down -v
```

## Monitoring and Alerting

### Backup Monitoring

Monitor backup operations using:

1. **Backup logs:**
   ```bash
   tail -f /var/lib/postgresql/data/walg_logs/backup_*.log
   ```

2. **Cron execution:**
   ```bash
   docker exec backup crontab -l
   ```

3. **Storage usage:**
   ```bash
   # For SSH storage
   ssh walg@backup-server 'du -sh /backup/path'
   
   # For local testing
   docker exec ssh-server du -sh /backups
   ```

### Telegram Notifications

Configure Telegram alerts for backup operations:

```bash
TELEGRAM_BOT_TOKEN=your_bot_token
TELEGRAM_CHAT_ID=your_chat_id
TELEGRAM_MESSAGE_PREFIX="PostgreSQL Backup"
```

## Future Enhancements

Planned improvements:

1. **Metrics collection** - Prometheus/Grafana integration
2. **Backup validation** - Automatic restore testing
3. **Multi-server testing** - Distributed backup scenarios
4. **Performance benchmarking** - Backup/restore timing metrics
5. **Cloud storage testing** - S3, GCS, Azure integration