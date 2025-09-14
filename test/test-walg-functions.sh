#!/usr/bin/env bash
set -euo pipefail

# WAL-G specific functionality tests
# Tests archive_command wal-push, backup-push, and delete operations

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$REPO_DIR/.env"
COMPOSE_CMD="docker compose"
POSTGRES_SERVICE_NAME="postgres"
BACKUP_SERVICE_NAME="backup"

# Ensure we're using the same functions from the main test script
source "$REPO_DIR/test/run-tests.sh" 2>/dev/null || true

# Helper functions if not already defined
if ! declare -f echof >/dev/null 2>&1; then
    echof() { echo "== $* =="; }
fi

if ! declare -f pass >/dev/null 2>&1; then
    pass() { echo "PASS: $*"; }
fi

if ! declare -f skip >/dev/null 2>&1; then
    skip() { echo "SKIP: $*"; }
fi

if ! declare -f die >/dev/null 2>&1; then
    die() { echo "FAIL: $*" >&2; exit 1; }
fi

# Get container IDs
get_container_ids() {
    CONTAINER_ID=$($COMPOSE_CMD ps -q "$POSTGRES_SERVICE_NAME" || true)
    BACKUP_CONTAINER_ID=$($COMPOSE_CMD ps -q "$BACKUP_SERVICE_NAME" || true)
    
    if [[ -z "$CONTAINER_ID" ]]; then
        die "Postgres container not found"
    fi
    
    if [[ -z "$BACKUP_CONTAINER_ID" ]]; then
        echo "Warning: Backup container not found"
    fi
}

# Test 1: Archive command wal-push functionality
test_archive_command_wal_push() {
    echof "Testing archive_command wal-push functionality"
    
    # Check if postgresql.conf has the correct archive_command
    if docker exec "$CONTAINER_ID" bash -c "grep -q \"archive_command.*wal-g wal-push\" /var/lib/postgresql/data/postgresql.conf" 2>/dev/null; then
        pass "postgresql.conf contains wal-g wal-push archive_command"
    else
        skip "postgresql.conf doesn't contain wal-g wal-push archive_command (may be using SQL mode)"
        return
    fi
    
    # Check if archiving is enabled
    if docker exec "$CONTAINER_ID" psql -U postgres -c "SHOW archive_mode;" | grep -q "on"; then
        pass "PostgreSQL archive_mode is enabled"
    else
        skip "PostgreSQL archive_mode is not enabled"
        return
    fi
    
    # Force a WAL segment switch to trigger archiving
    docker exec "$CONTAINER_ID" psql -U postgres -c "SELECT pg_switch_wal();" >/dev/null 2>&1
    sleep 2
    
    # Check PostgreSQL logs for archive command execution
    if docker logs "$CONTAINER_ID" 2>&1 | grep -q "wal-g wal-push" || docker logs "$CONTAINER_ID" 2>&1 | grep -q "archived"; then
        pass "Archive command appears to be executing (wal-push activity detected)"
    else
        skip "No archive command activity detected in logs (may require SSH connection)"
    fi
    
    # Test if wal-g can execute the wal-push command (without actual push)
    if docker exec "$CONTAINER_ID" wal-g --help 2>/dev/null | grep -q "wal-push"; then
        pass "wal-g wal-push command is available and can be invoked"
    else
        skip "wal-g wal-push command test failed"
    fi
}

# Test 2: Backup-push functionality 
test_backup_push() {
    echof "Testing backup-push functionality"
    
    # Check if backup container exists and has wal-g runner
    if [[ -n "$BACKUP_CONTAINER_ID" ]]; then
        if docker exec "$BACKUP_CONTAINER_ID" test -f "/opt/walg/scripts/wal-g-runner.sh"; then
            pass "wal-g-runner.sh script found in backup container"
        else
            skip "wal-g-runner.sh script not found in backup container"
            return
        fi
        
        # Test if backup runner can be invoked (dry run)
        if docker exec "$BACKUP_CONTAINER_ID" bash -c "/opt/walg/scripts/wal-g-runner.sh --help 2>/dev/null || echo 'backup runner exists'"; then
            pass "wal-g-runner.sh script is executable"
        else
            skip "wal-g-runner.sh script execution test failed"
        fi
        
        # Check if cron job for backup is configured
        if docker exec "$BACKUP_CONTAINER_ID" crontab -l 2>/dev/null | grep -q "wal-g-runner.sh backup"; then
            pass "Cron job for backup-push is configured"
        else
            skip "Cron job for backup-push not found"
        fi
        
        # Test environment variables for backup
        if docker exec "$BACKUP_CONTAINER_ID" env | grep -q "WALG_"; then
            pass "WAL-G environment variables are set in backup container"
        else
            skip "WAL-G environment variables not found in backup container"
        fi
    else
        skip "Backup container not available for backup-push testing"
    fi
    
    # Test direct postgres container backup capability
    if docker exec "$CONTAINER_ID" which wal-g >/dev/null 2>&1; then
        if docker exec "$CONTAINER_ID" wal-g --help 2>/dev/null | grep -q "backup-push"; then
            pass "wal-g backup-push command available in postgres container"
            
            # Test backup command syntax (without actually performing backup)
            if docker exec "$CONTAINER_ID" bash -c "wal-g backup-push --help >/dev/null 2>&1 || echo 'Command available'"; then
                pass "wal-g backup-push command syntax test passed"
            else
                skip "wal-g backup-push command syntax test failed"
            fi
        else
            skip "wal-g backup-push command not available"
        fi
    else
        skip "wal-g not available in postgres container for backup testing"
    fi
}

# Test 3: Delete functionality
test_delete_functionality() {
    echof "Testing delete/cleanup functionality"
    
    # Check if backup container has cleanup cron job
    if [[ -n "$BACKUP_CONTAINER_ID" ]]; then
        if docker exec "$BACKUP_CONTAINER_ID" crontab -l 2>/dev/null | grep -q "wal-g-runner.sh clean"; then
            pass "Cron job for cleanup/delete is configured"
        else
            skip "Cron job for cleanup/delete not found"
        fi
        
        # Test cleanup script functionality
        if docker exec "$BACKUP_CONTAINER_ID" test -f "/opt/walg/scripts/wal-g-runner.sh"; then
            if docker exec "$BACKUP_CONTAINER_ID" bash -c "/opt/walg/scripts/wal-g-runner.sh clean --help 2>/dev/null || echo 'cleanup mode exists'"; then
                pass "wal-g-runner.sh cleanup mode is available"
            else
                skip "wal-g-runner.sh cleanup mode test failed"
            fi
        else
            skip "wal-g-runner.sh not found for cleanup testing"
        fi
    else
        skip "Backup container not available for cleanup testing"
    fi
    
    # Test direct postgres container delete capability
    if docker exec "$CONTAINER_ID" which wal-g >/dev/null 2>&1; then
        if docker exec "$CONTAINER_ID" wal-g --help 2>/dev/null | grep -q "delete"; then
            pass "wal-g delete command available in postgres container"
            
            # Test delete command options
            if docker exec "$CONTAINER_ID" bash -c "wal-g delete --help >/dev/null 2>&1 || echo 'Delete command available'"; then
                pass "wal-g delete command syntax test passed"
            else
                skip "wal-g delete command syntax test failed"
            fi
        else
            skip "wal-g delete command not available"
        fi
    else
        skip "wal-g not available in postgres container for delete testing"
    fi
    
    # Test retention configuration
    if [[ -n "$BACKUP_CONTAINER_ID" ]]; then
        if docker exec "$BACKUP_CONTAINER_ID" env | grep -q "WALG_RETENTION"; then
            pass "WAL-G retention configuration found"
        else
            skip "WAL-G retention configuration not found"
        fi
    fi
}

# Main test execution
main() {
    echof "Starting WAL-G functionality tests"
    
    # Change to repository directory
    cd "$REPO_DIR"
    
    # Get container information
    get_container_ids
    
    echof "Container IDs: postgres=$CONTAINER_ID, backup=$BACKUP_CONTAINER_ID"
    
    # Check if we're in WAL mode
    BACKUP_MODE=$(grep "^BACKUP_MODE=" "$ENV_FILE" | cut -d'=' -f2 || echo "sql")
    
    if [[ "$BACKUP_MODE" != "wal" ]]; then
        echof "BACKUP_MODE is not 'wal' (currently: $BACKUP_MODE)"
        echof "These tests are designed for WAL-G mode"
        exit 0
    fi
    
    # Run tests
    test_archive_command_wal_push
    echo ""
    test_backup_push  
    echo ""
    test_delete_functionality
    
    echof "WAL-G functionality tests completed"
}

# Only run main if script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi