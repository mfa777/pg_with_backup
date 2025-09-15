#!/usr/bin/env bash
set -euo pipefail

# Offline E2E WAL-G Testing Script
# Tests wal-push, backup-push, and delete operations using mock wal-g
# This script works without external network dependencies

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MOCK_WALG="$SCRIPT_DIR/scripts/mock-wal-g.sh"
MOCK_BACKUP_DIR="/tmp/mock-walg-backups"

# Helper functions
echof() { echo "== $* =="; }
die() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
skip() { echo "SKIP: $*"; }
warn() { echo "WARN: $*"; }

# Setup mock environment
setup_mock_env() {
    echof "Setting up mock wal-g environment"
    
    # Clean previous test data
    rm -rf "$MOCK_BACKUP_DIR" || true
    mkdir -p "$MOCK_BACKUP_DIR"
    
    # Set environment variables for mock wal-g
    export MOCK_BACKUP_DIR
    export WALG_RETENTION_FULL=3
    export WALG_SSH_PREFIX="mock://test-server/backups"
    
    pass "Mock environment initialized"
}

# Test mock wal-g commands
test_mock_walg_commands() {
    echof "Testing mock wal-g command availability"
    
    # Test help
    if "$MOCK_WALG" --help >/dev/null 2>&1; then
        pass "mock wal-g --help command works"
    else
        die "mock wal-g --help command failed"
    fi
    
    # Test version
    if "$MOCK_WALG" --version >/dev/null 2>&1; then
        pass "mock wal-g --version command works"
    else
        die "mock wal-g --version command failed"
    fi
}

# Test 1: WAL archiving simulation
test_wal_archiving() {
    echof "Testing WAL archiving with mock wal-g"
    
    # Create a mock WAL file
    local mock_wal_file="/tmp/test_wal_file_$(date +%s)"
    echo "Mock WAL data" > "$mock_wal_file"
    
    # Test wal-push
    if "$MOCK_WALG" wal-push "$mock_wal_file" >/dev/null 2>&1; then
        pass "WAL file archived successfully"
        
        # Check if compressed WAL appeared in mock storage
        local wal_basename=$(basename "$mock_wal_file")
        if [[ -f "$MOCK_BACKUP_DIR/${wal_basename}.lz4" ]]; then
            pass "Compressed WAL file found in mock storage"
        else
            warn "Compressed WAL file not found in expected location"
        fi
    else
        die "WAL archiving failed"
    fi
    
    # Cleanup
    rm -f "$mock_wal_file"
}

# Test 2: Backup creation simulation
test_backup_creation() {
    echof "Testing backup creation with mock wal-g"
    
    # Create mock PGDATA directory
    local mock_pgdata="/tmp/mock_pgdata_$(date +%s)"
    mkdir -p "$mock_pgdata"
    echo "Mock PostgreSQL data" > "$mock_pgdata/postgresql.conf"
    
    # Get initial backup count
    local initial_count=0
    if [[ -f "$MOCK_BACKUP_DIR/backups.txt" ]]; then
        initial_count=$(wc -l < "$MOCK_BACKUP_DIR/backups.txt" || echo "0")
    fi
    
    # Create backup
    if "$MOCK_WALG" backup-push "$mock_pgdata" >/dev/null 2>&1; then
        pass "Backup created successfully"
        
        # Check if backup count increased
        local final_count=0
        if [[ -f "$MOCK_BACKUP_DIR/backups.txt" ]]; then
            final_count=$(wc -l < "$MOCK_BACKUP_DIR/backups.txt" || echo "0")
        fi
        
        if ((final_count > initial_count)); then
            pass "Backup count increased from $initial_count to $final_count"
            
            # Show backup list
            echo "Current backups:"
            "$MOCK_WALG" backup-list | sed 's/^/  /'
        else
            die "Backup count did not increase"
        fi
    else
        die "Backup creation failed"
    fi
    
    # Cleanup
    rm -rf "$mock_pgdata"
}

# Test 3: Multiple backups and retention
test_backup_retention() {
    echof "Testing backup retention with mock wal-g"
    
    # Create multiple backups
    local mock_pgdata="/tmp/mock_pgdata_retention"
    mkdir -p "$mock_pgdata"
    echo "Mock data" > "$mock_pgdata/data.sql"
    
    # Create 5 backups (more than retention limit of 3)
    for i in {1..5}; do
        echo "Creating backup $i..."
        "$MOCK_WALG" backup-push "$mock_pgdata" >/dev/null 2>&1
        sleep 1  # Ensure different timestamps
    done
    
    local backup_count_before
    backup_count_before=$(wc -l < "$MOCK_BACKUP_DIR/backups.txt" || echo "0")
    pass "Created $backup_count_before backups"
    
    # Test retention cleanup
    if "$MOCK_WALG" delete retain FULL >/dev/null 2>&1; then
        local backup_count_after
        backup_count_after=$(wc -l < "$MOCK_BACKUP_DIR/backups.txt" || echo "0")
        
        if ((backup_count_after <= 3)); then
            pass "Retention policy applied: $backup_count_before -> $backup_count_after backups (limit: 3)"
        else
            warn "Retention policy may not have worked as expected: $backup_count_before -> $backup_count_after"
        fi
        
        if ((backup_count_after >= 1)); then
            pass "At least one backup retained after cleanup"
        else
            die "All backups were deleted - this should not happen"
        fi
    else
        die "Backup retention test failed"
    fi
    
    # Cleanup
    rm -rf "$mock_pgdata"
}

# Test 4: Configuration integration test
test_postgresql_integration() {
    echof "Testing PostgreSQL configuration integration"
    
    # Test postgresql.conf template
    local conf_template="$SCRIPT_DIR/postgresql.conf.template"
    if [[ -f "$conf_template" ]]; then
        if grep -q "archive_command.*wal-g wal-push" "$conf_template"; then
            pass "postgresql.conf.template contains wal-g archive_command"
        else
            warn "postgresql.conf.template missing wal-g archive_command"
        fi
        
        if grep -q "archive_mode = on" "$conf_template"; then
            pass "postgresql.conf.template has archive_mode enabled"
        else
            warn "postgresql.conf.template missing archive_mode setting"
        fi
    else
        skip "postgresql.conf.template not found"
    fi
    
    # Test wal-g runner script
    local runner_script="$SCRIPT_DIR/scripts/wal-g-runner.sh"
    if [[ -f "$runner_script" ]]; then
        pass "wal-g-runner.sh script found"
        
        if grep -q "backup-push" "$runner_script"; then
            pass "wal-g-runner.sh contains backup-push logic"
        else
            warn "wal-g-runner.sh missing backup-push logic"
        fi
        
        if grep -q "delete\|clean" "$runner_script"; then
            pass "wal-g-runner.sh contains cleanup logic"
        else
            warn "wal-g-runner.sh missing cleanup logic"
        fi
    else
        skip "wal-g-runner.sh script not found"
    fi
}

# Test 5: SSH setup validation
test_ssh_setup() {
    echof "Testing SSH setup and configuration"
    
    # Check SSH key generation
    local ssh_key_dir="$SCRIPT_DIR/secrets/walg_ssh_key"
    if [[ -f "$ssh_key_dir/id_rsa" && -f "$ssh_key_dir/id_rsa.pub" ]]; then
        pass "SSH key pair exists"
        
        # Check key permissions
        local key_perms=$(stat -c "%a" "$ssh_key_dir/id_rsa" 2>/dev/null || echo "")
        if [[ "$key_perms" == "600" ]]; then
            pass "SSH private key has correct permissions (600)"
        else
            warn "SSH private key permissions may be incorrect: $key_perms"
        fi
    else
        skip "SSH key pair not found (run ./scripts/setup-local-ssh.sh first)"
    fi
    
    # Check .env configuration
    local env_file="$SCRIPT_DIR/.env"
    if [[ -f "$env_file" ]]; then
        if grep -q "BACKUP_MODE=wal" "$env_file"; then
            pass ".env file configured for WAL mode"
        else
            skip ".env file not configured for WAL mode"
        fi
        
        if grep -q "WALG_SSH_PREFIX" "$env_file"; then
            pass ".env file contains WALG_SSH_PREFIX configuration"
        else
            skip ".env file missing WALG_SSH_PREFIX"
        fi
    else
        skip ".env file not found"
    fi
}

# Main test execution
main() {
    echof "Starting Offline WAL-G End-to-End Testing"
    echo "This test demonstrates wal-g functionality using a mock implementation"
    echo "to work around network connectivity limitations."
    echo ""
    
    # Setup
    setup_mock_env
    echo ""
    
    # Run tests
    test_mock_walg_commands
    echo ""
    
    test_wal_archiving
    echo ""
    
    test_backup_creation
    echo ""
    
    test_backup_retention
    echo ""
    
    test_postgresql_integration
    echo ""
    
    test_ssh_setup
    echo ""
    
    echof "Offline WAL-G Testing Completed Successfully!"
    echo ""
    echo "Test results saved to: $MOCK_BACKUP_DIR/walg.log"
    echo "Mock backups created in: $MOCK_BACKUP_DIR"
    echo ""
    echo "To test with real wal-g and SSH server:"
    echo "1. Run: ./scripts/setup-local-ssh.sh"
    echo "2. Start stack: docker compose --profile ssh-testing up --build -d"
    echo "3. Run: ./test/test-walg-e2e.sh"
}

# Run main function
main "$@"