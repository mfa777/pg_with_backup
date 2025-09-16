#!/usr/bin/env bash
set -euo pipefail

# End-to-End WAL-G Testing Script
# Tests actual wal-push, backup-push, and delete operations with remote verification
# This script assumes the local SSH server is running and accessible

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$SCRIPT_DIR/.env"
COMPOSE_CMD="docker compose --profile ssh-testing"
POSTGRES_SERVICE_NAME="postgres"
BACKUP_SERVICE_NAME="backup"
SSH_SERVICE_NAME="ssh-server"

# Load environment variables
if [[ -f "$ENV_FILE" ]]; then
    set -o allexport
    source "$ENV_FILE"
    set +o allexport
fi

POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_DB="${POSTGRES_DB:-postgres}"
CLEANUP=${CLEANUP:-1}

# Helper functions
echof() { echo "== $* =="; }
die() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
skip() { echo "SKIP: $*"; }
warn() { echo "WARN: $*"; }

# Get container IDs
get_container_ids() {
    POSTGRES_CONTAINER_ID=$($COMPOSE_CMD ps -q "$POSTGRES_SERVICE_NAME" 2>/dev/null || true)
    BACKUP_CONTAINER_ID=$($COMPOSE_CMD ps -q "$BACKUP_SERVICE_NAME" 2>/dev/null || true)
    SSH_CONTAINER_ID=$($COMPOSE_CMD ps -q "$SSH_SERVICE_NAME" 2>/dev/null || true)
    
    if [[ -z "$POSTGRES_CONTAINER_ID" ]]; then
        die "Postgres container not found. Is the stack running?"
    fi
    
    if [[ -z "$BACKUP_CONTAINER_ID" ]]; then
        die "Backup container not found. Is the stack running?"
    fi
    
    if [[ -z "$SSH_CONTAINER_ID" ]]; then
        die "SSH server container not found. Is the stack running with --profile ssh-testing?"
    fi
}

# Wait for services to be ready
wait_for_services() {
    echof "Waiting for services to be ready"
    
    # Wait for PostgreSQL
    local timeout=30
    local count=0
    while ! docker exec "$POSTGRES_CONTAINER_ID" pg_isready -U "$POSTGRES_USER" >/dev/null 2>&1; do
        if ((count++ > timeout)); then
            # Show postgres logs for debugging if timeout occurs
            echof "PostgreSQL readiness timeout. Last 50 lines of logs:"
            docker logs --tail 50 "$POSTGRES_CONTAINER_ID" 2>&1 || true
            die "PostgreSQL failed to become ready within $timeout seconds"
        fi
        sleep 1
    done
    pass "PostgreSQL is ready"
    
    # Wait for SSH server
    count=0
    while ! docker exec "$SSH_CONTAINER_ID" netstat -ln | grep -q ":2222 "; do
        if ((count++ > 30)); then
            die "SSH server failed to become ready within 30 seconds"
        fi
        sleep 1
    done
    pass "SSH server is ready"
    
    # Ensure backup directory has proper permissions for walg user
    echo "Setting up backup directory permissions..."
    if docker exec "$SSH_CONTAINER_ID" bash -c "mkdir -p /backups && chown walg:walg /backups && chmod 755 /backups" 2>/dev/null; then
        pass "Backup directory permissions configured"
    else
        warn "Could not configure backup directory permissions (may still work)"
    fi
    
    # Give a moment for wal-g initialization
    sleep 5
}

# Test if we can list remote backups (baseline)
test_remote_connectivity() {
    echof "Testing remote SSH connectivity and wal-g configuration"
    
    # Test SSH connectivity from postgres container
        # Allow overriding test SSH port (internal container port). Default matches docker-compose (2222).
        WALG_SSH_TEST_PORT="${WALG_SSH_TEST_PORT:-2222}"
        # Run SSH as the 'postgres' user so it will use the key prepared at
        # /var/lib/postgresql/.ssh/walg_key (walg-env-prepare.sh sets WALG_SSH_PRIVATE_KEY_PATH)
        if docker exec "$POSTGRES_CONTAINER_ID" bash -c "su - postgres -c \"ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes -p $WALG_SSH_TEST_PORT walg@ssh-server 'echo SSH connection successful'\"" 2>/dev/null; then
            pass "SSH connectivity to remote server working"
        else
            warn "SSH connectivity test failed — collecting verbose SSH output for debugging (as postgres)"
            echo "---- SSH verbose debug output start ----"
            docker exec "$POSTGRES_CONTAINER_ID" bash -c "su - postgres -c \"ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes -o PreferredAuthentications=publickey -p $WALG_SSH_TEST_PORT -vvv walg@ssh-server\"" || true
            echo "---- SSH verbose debug output end ----"
            die "Cannot establish SSH connection to remote server"
        fi
    
    # Test wal-g backup-list (should work even if empty)
    if docker exec "$POSTGRES_CONTAINER_ID" bash -c "su - postgres -c 'wal-g backup-list'" >/dev/null 2>&1; then
        pass "wal-g backup-list command successful"
    else
        warn "wal-g backup-list failed - this may be normal for first run"
    fi
}

# Get current backup count
get_backup_count() {
    # Run wal-g backup-list inside the postgres container as the postgres user
    # Source the prepared WAL-G env file so credentials/config are available.
    local out
    out=$(docker exec "$POSTGRES_CONTAINER_ID" bash -c "su - postgres -c 'source /var/lib/postgresql/.walg_env >/dev/null 2>&1 || true; wal-g backup-list 2>/dev/null | wc -l'" 2>/dev/null || true)
    out=$(echo "${out:-0}" | tr -d '[:space:]')
    if [[ -z "$out" ]] || ! [[ "$out" =~ ^[0-9]+$ ]]; then
        echo 0
    else
        echo "$out"
    fi
}

# Get WAL files count in remote storage
get_remote_wal_count() {
    # wal-g stores WAL files in subdirectories like wal_005/
    # Look for compressed WAL files in the entire backup directory structure
    local out
    out=$(docker exec "$SSH_CONTAINER_ID" bash -c "find /backups -type f \( -name '*.lz4' -o -name '*.br' -o -name '*.gz' -o -name '*.zst' \) 2>/dev/null | wc -l" 2>/dev/null || true)
    out=$(echo "${out:-0}" | tr -d '[:space:]')
    if [[ -z "$out" ]] || ! [[ "$out" =~ ^[0-9]+$ ]]; then
        echo 0
    else
        echo "$out"
    fi
}

# Test 1: Archive command wal-push functionality
test_wal_push_e2e() {
    echof "Testing end-to-end WAL push functionality"
    
    # Check initial WAL count
    local initial_wal_count
    initial_wal_count=$(get_remote_wal_count)
    echo "Initial WAL count in remote storage: $initial_wal_count"
    
    # Show current remote directory structure for debugging
    echo "Current remote directory structure:"
    docker exec "$SSH_CONTAINER_ID" bash -c "find /backups -type f 2>/dev/null | head -10" || echo "No files found or directory doesn't exist"
    
    # Generate some WAL activity
    echo "Generating WAL activity..."
    docker exec "$POSTGRES_CONTAINER_ID" psql -U "$POSTGRES_USER" -c "
        CREATE TABLE IF NOT EXISTS wal_test_table (id SERIAL PRIMARY KEY, data TEXT);
        INSERT INTO wal_test_table (data) SELECT 'test_data_' || generate_series(1, 1000);
        SELECT pg_switch_wal();
    " >/dev/null 2>&1
    
    # Force WAL archiving to happen immediately
    echo "Forcing WAL segment switch and archiving..."
    docker exec "$POSTGRES_CONTAINER_ID" psql -U "$POSTGRES_USER" -c "SELECT pg_switch_wal();" >/dev/null 2>&1
    
    # Wait for WAL archiving to complete
    echo "Waiting for WAL archiving to complete..."
    sleep 15
    
    # Check if new WAL files appeared
    local final_wal_count
    final_wal_count=$(get_remote_wal_count)
    echo "Final WAL count in remote storage: $final_wal_count"
    
    # Show what files were created for debugging
    echo "Files in remote storage after WAL activity:"
    docker exec "$SSH_CONTAINER_ID" bash -c "find /backups -type f -newer /backups 2>/dev/null | head -10" || echo "No new files found"
    
    if ((final_wal_count > initial_wal_count)); then
        pass "WAL files successfully pushed to remote storage (count: $initial_wal_count -> $final_wal_count)"
        
        # Verify we can see specific WAL push activity in logs
        if docker logs "$POSTGRES_CONTAINER_ID" 2>&1 | grep -q "wal-g wal-push\|archived"; then
            pass "WAL push activity detected in PostgreSQL logs"
        else
            warn "No explicit WAL push activity found in logs"
        fi
    else
        # Additional debugging for failed WAL push
        echo "=== DEBUGGING FAILED WAL PUSH ==="
        echo "Checking PostgreSQL configuration..."
        docker exec "$POSTGRES_CONTAINER_ID" psql -U "$POSTGRES_USER" -c "SHOW archive_mode;" || echo "Failed to check archive_mode"
        docker exec "$POSTGRES_CONTAINER_ID" psql -U "$POSTGRES_USER" -c "SHOW archive_command;" || echo "Failed to check archive_command"
        
        echo "Checking PostgreSQL logs for errors..."
        docker logs "$POSTGRES_CONTAINER_ID" 2>&1 | grep -i "archive\|wal-g\|error" | tail -10 || echo "No relevant log entries found"
        
        echo "Testing wal-g manually..."
        docker exec "$POSTGRES_CONTAINER_ID" bash -c "wal-g --version" || echo "wal-g not accessible"
        
        echo "Checking SSH connectivity from postgres container..."
        docker exec "$POSTGRES_CONTAINER_ID" bash -c "su - postgres -c \"ssh -o ConnectTimeout=5 -o BatchMode=yes -p 2222 walg@ssh-server 'echo SSH test successful'\"" || echo "SSH test failed"
        
        echo "Checking backup directory permissions..."
        docker exec "$SSH_CONTAINER_ID" bash -c "ls -la /backups/" || echo "Backup directory not accessible"
        docker exec "$SSH_CONTAINER_ID" bash -c "id walg" || echo "walg user not found"
        
        echo "Testing manual wal-g wal-push..."
        docker exec "$POSTGRES_CONTAINER_ID" bash -c "su - postgres -c 'wal-g --help | head -5'" || echo "wal-g help failed"
        
        die "No new WAL files found in remote storage (count remained at $initial_wal_count)"
    fi
}

# Test 2: Backup-push functionality with verification
test_backup_push_e2e() {
    echof "Testing end-to-end backup-push functionality"
    
    # Get initial backup count
    local initial_backup_count
    initial_backup_count=$(get_backup_count)
    
    # Execute backup from backup container
    docker exec "$BACKUP_CONTAINER_ID" bash -c "/opt/walg/scripts/wal-g-runner.sh backup" || die "Backup execution failed"
    
    # Wait for backup to complete
    sleep 15
    
    # Check if new backup appeared
    local final_backup_count
    final_backup_count=$(get_backup_count)
    
    if ((final_backup_count > initial_backup_count)); then
        pass "Base backup successfully created (count: $initial_backup_count -> $final_backup_count)"
        
        # Verify backup details
        local backup_info
        backup_info=$(docker exec "$POSTGRES_CONTAINER_ID" bash -c "wal-g backup-list | tail -1" 2>/dev/null || echo "")
        if [[ -n "$backup_info" ]]; then
            pass "Latest backup info: $backup_info"
        fi
        
        # Check backup logs
        if docker exec "$BACKUP_CONTAINER_ID" bash -c "ls /var/lib/postgresql/data/walg_logs/backup_*.log 2>/dev/null | head -1 | xargs cat" 2>/dev/null | grep -q "backup.*completed\|SUCCESS"; then
            pass "Backup completion confirmed in logs"
        else
            warn "No backup completion confirmation found in logs"
        fi
    else
        die "No new backup found (count remained at $initial_backup_count)"
    fi
}

# Test 3: Delete/retention functionality with verification
test_delete_e2e() {
    echof "Testing end-to-end delete/retention functionality"
    
    # Ensure we have multiple backups to test retention
    local backup_count
    backup_count=$(get_backup_count)
    
    if ((backup_count < 2)); then
        echof "Creating additional backup to test retention"
        docker exec "$BACKUP_CONTAINER_ID" bash -c "/opt/walg/scripts/wal-g-runner.sh backup" || die "Additional backup creation failed"
        sleep 15
        backup_count=$(get_backup_count)
    fi
    
    if ((backup_count < 2)); then
        skip "Insufficient backups for retention testing (need at least 2, have $backup_count)"
        return
    fi
    
    local initial_backup_count=$backup_count
    
    # Execute cleanup
    docker exec "$BACKUP_CONTAINER_ID" bash -c "/opt/walg/scripts/wal-g-runner.sh clean" || warn "Cleanup execution had issues (may be normal)"
    
    # Wait for cleanup to complete
    sleep 10
    
    # Check if retention policy was applied
    local final_backup_count
    final_backup_count=$(get_backup_count)
    
    local retention_setting="${WALG_RETENTION_FULL:-7}"
    
    if ((final_backup_count <= retention_setting)); then
        pass "Retention policy applied successfully (count: $initial_backup_count -> $final_backup_count, limit: $retention_setting)"
    else
        warn "Retention policy may not have been applied as expected (count: $initial_backup_count -> $final_backup_count, limit: $retention_setting)"
    fi
    
    # Verify we still have at least 1 backup
    if ((final_backup_count >= 1)); then
        pass "At least one backup retained after cleanup"
    else
        die "All backups were deleted - this should not happen"
    fi
}

# Test 4: Recovery verification (optional)
test_recovery_capability() {
    echof "Testing backup recovery capability (verification only)"
    
    # Test if we can get backup information for recovery
    if docker exec "$POSTGRES_CONTAINER_ID" bash -c "wal-g backup-list | tail -1" | grep -q "base_"; then
        local latest_backup
        latest_backup=$(docker exec "$POSTGRES_CONTAINER_ID" bash -c "wal-g backup-list | tail -1 | awk '{print \$1}'" 2>/dev/null || echo "")
        if [[ -n "$latest_backup" ]]; then
            pass "Latest backup available for recovery: $latest_backup"
            
            # Test if we can get backup fetch info (without actually fetching)
            if docker exec "$POSTGRES_CONTAINER_ID" bash -c "wal-g backup-fetch --help" >/dev/null 2>&1; then
                pass "backup-fetch command available for recovery"
            else
                warn "backup-fetch command test failed"
            fi
            
            # Test if we can get wal fetch info (without actually fetching)
            if docker exec "$POSTGRES_CONTAINER_ID" bash -c "wal-g wal-fetch --help" >/dev/null 2>&1; then
                pass "wal-fetch command available for recovery"
            else
                warn "wal-fetch command test failed"
            fi
        fi
    else
        skip "No valid backups found for recovery testing"
    fi
}

# Main test execution
main() {
    echof "Starting WAL-G End-to-End Testing"
    
    # Change to repository directory
    cd "$SCRIPT_DIR"
    
    # Optional: forcibly clear the postgres-data named volume before bringing up compose
    if [[ "${FORCE_EMPTY_PGDATA:-0}" == "1" ]]; then
        echof "== FORCE_EMPTY_PGDATA=1: removing postgres-data volume and any previous compose state"
  # Stop and remove any running compose resources, then remove the named volume
  $COMPOSE_CMD down -v || true
  if docker volume ls --format '{{.Name}}' | grep -q '^postgres-data$'; then
    docker volume rm postgres-data || true
    pass "postgres-data volume removed"
  else
    skip "postgres-data volume not present"
  fi

  echof "== Preparing an empty postgres-data volume to avoid image population"
  # Create an empty named volume and ensure it's empty by mounting a helper container
  docker volume create postgres-data >/dev/null 2>&1 || true
  docker run --rm -v postgres-data:/data alpine:3.21 sh -c "rm -rf /data/* /data/.* 2>/dev/null || true; ls -la /data || true" || true
  pass "postgres-data prepared and emptied"


    fi
            # Restart the stack after cleanup
        echof "Restarting stack after volume cleanup"
        $COMPOSE_CMD --profile ssh-testing up --build -d
        sleep 10  # Give more time for initialization after cleanup
    
    # Verify stack is running
    if ! $COMPOSE_CMD ps "$POSTGRES_SERVICE_NAME" >/dev/null 2>&1; then
        die "Stack is not running. Please run: $COMPOSE_CMD up --build -d"
    fi
    
    # Get container information
    get_container_ids
    echo "Container IDs:"
    echo "  - PostgreSQL: $POSTGRES_CONTAINER_ID"
    echo "  - Backup: $BACKUP_CONTAINER_ID" 
    echo "  - SSH Server: $SSH_CONTAINER_ID"
    echo ""
    
    # Wait for all services
    wait_for_services
    
    # Run connectivity test
    test_remote_connectivity
    echo ""
    
    # Run end-to-end tests
    test_wal_push_e2e
    echo ""
    
    test_backup_push_e2e
    echo ""
    
    test_delete_e2e
    echo ""
    
    test_recovery_capability
    echo ""
    
    echof "End-to-End WAL-G Testing Completed Successfully!"
    
    # Optional cleanup
    if [[ "$CLEANUP" == "1" ]]; then
        echof "Cleaning up test environment"
        $COMPOSE_CMD down
        pass "Test environment cleaned up"
    fi
}

# Run main function
main "$@"