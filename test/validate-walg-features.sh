#!/usr/bin/env bash
set -euo pipefail

# WAL-G Feature Validation Script
# Tests the core WAL-G setup without requiring running containers
# Useful for validating configuration and setup

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Helper functions
echof() { echo "== $* =="; }
die() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "PASS: $*"; }
skip() { echo "SKIP: $*"; }
warn() { echo "WARN: $*"; }

# Test 1: Configuration files exist and have correct content
test_configuration_files() {
    echof "Testing configuration files"
    
    # Check postgresql.conf.template
    local pg_conf="$SCRIPT_DIR/postgresql.conf.template"
    if [[ -f "$pg_conf" ]]; then
        if grep -q "archive_command.*wal-g wal-push" "$pg_conf"; then
            pass "postgresql.conf.template contains wal-g archive_command"
        else
            warn "postgresql.conf.template missing wal-g archive_command"
        fi
        
        if grep -q "archive_mode = on" "$pg_conf"; then
            pass "postgresql.conf.template has archive_mode enabled"
        else
            warn "postgresql.conf.template missing archive_mode setting"
        fi
    else
        die "postgresql.conf.template not found"
    fi
    
    # Check docker-compose.yml
    local compose_file="$SCRIPT_DIR/docker-compose.yml"
    if [[ -f "$compose_file" ]]; then
        if grep -q "ssh-server:" "$compose_file"; then
            pass "docker-compose.yml includes SSH server service"
        else
            warn "docker-compose.yml missing SSH server service"
        fi
        
        if grep -q "profiles:" "$compose_file"; then
            pass "docker-compose.yml includes profiles for testing"
        else
            warn "docker-compose.yml missing testing profiles"
        fi
    else
        die "docker-compose.yml not found"
    fi
}

# Test 2: Scripts exist and are executable
test_script_availability() {
    echof "Testing script availability"
    
    local scripts=(
        "scripts/wal-g-runner.sh"
        "scripts/walg-env-prepare.sh"
        "scripts/setup-local-ssh.sh"
        "test/test-walg-e2e.sh"
        "test/test-offline-e2e.sh"
        "scripts/mock-wal-g.sh"
    )
    
    for script in "${scripts[@]}"; do
        local script_path="$SCRIPT_DIR/$script"
        if [[ -f "$script_path" ]]; then
            if [[ -x "$script_path" ]]; then
                pass "$script exists and is executable"
            else
                warn "$script exists but is not executable"
            fi
        else
            warn "$script not found"
        fi
    done
}

# Test 3: Environment configuration
test_environment_config() {
    echof "Testing environment configuration"
    
    local env_sample="$SCRIPT_DIR/env_sample"
    if [[ -f "$env_sample" ]]; then
        if grep -q "BACKUP_MODE=" "$env_sample"; then
            pass "env_sample contains BACKUP_MODE setting"
        fi
        
        if grep -q "WALG_SSH_PREFIX" "$env_sample"; then
            pass "env_sample contains WALG_SSH_PREFIX setting"
        fi
        
        if grep -q "ENABLE_SSH_SERVER" "$env_sample"; then
            pass "env_sample contains SSH server testing configuration"
        else
            warn "env_sample missing SSH server testing configuration"
        fi
    else
        die "env_sample not found"
    fi
    
    # Check .env if it exists
    local env_file="$SCRIPT_DIR/.env"
    if [[ -f "$env_file" ]]; then
        local backup_mode=$(grep "^BACKUP_MODE=" "$env_file" | cut -d'=' -f2 || echo "unknown")
        pass ".env file exists with BACKUP_MODE=$backup_mode"
        
        if [[ "$backup_mode" == "wal" ]]; then
            if grep -q "POSTGRES_DOCKERFILE=Dockerfile.postgres-walg" "$env_file"; then
                pass ".env configured for WAL mode with correct Dockerfile"
            else
                warn ".env WAL mode may be missing Dockerfile setting"
            fi
        fi
    else
        skip ".env file not found (run setup-local-ssh.sh to create)"
    fi
}

# Test 4: SSH key setup (if exists)
test_ssh_setup() {
    echof "Testing SSH key setup"
    
    local ssh_key_dir="$SCRIPT_DIR/secrets/walg_ssh_key"
    if [[ -d "$ssh_key_dir" ]]; then
        if [[ -f "$ssh_key_dir/id_rsa" && -f "$ssh_key_dir/id_rsa.pub" ]]; then
            pass "SSH key pair exists"
            
            # Check permissions
            local key_perms=$(stat -c "%a" "$ssh_key_dir/id_rsa" 2>/dev/null || echo "")
            if [[ "$key_perms" == "600" ]]; then
                pass "SSH private key has correct permissions (600)"
            else
                warn "SSH private key permissions: $key_perms (should be 600)"
            fi
            
            local pub_perms=$(stat -c "%a" "$ssh_key_dir/id_rsa.pub" 2>/dev/null || echo "")
            if [[ "$pub_perms" == "644" ]]; then
                pass "SSH public key has correct permissions (644)"
            else
                warn "SSH public key permissions: $pub_perms (should be 644)"
            fi
        else
            skip "SSH key pair not found (run setup-local-ssh.sh to generate)"
        fi
    else
        skip "SSH key directory not found"
    fi
}

# Test 5: Dockerfile validation
test_dockerfile_structure() {
    echof "Testing Dockerfile structure"
    
    local walg_dockerfile="$SCRIPT_DIR/Dockerfile.postgres-walg"
    if [[ -f "$walg_dockerfile" ]]; then
        if grep -q "wal-g" "$walg_dockerfile"; then
            pass "Dockerfile.postgres-walg contains wal-g installation"
        else
            warn "Dockerfile.postgres-walg missing wal-g installation"
        fi
        
        if grep -q "ssh" "$walg_dockerfile"; then
            pass "Dockerfile.postgres-walg includes SSH client"
        else
            warn "Dockerfile.postgres-walg missing SSH client"
        fi
        
        if grep -q "docker-entrypoint-walg.sh" "$walg_dockerfile"; then
            pass "Dockerfile.postgres-walg uses custom entrypoint"
        else
            warn "Dockerfile.postgres-walg missing custom entrypoint"
        fi
    else
        die "Dockerfile.postgres-walg not found"
    fi
    
    local backup_dockerfile="$SCRIPT_DIR/Dockerfile.backup"
    if [[ -f "$backup_dockerfile" ]]; then
        pass "Dockerfile.backup exists"
    else
        warn "Dockerfile.backup not found"
    fi
}

# Test 6: Mock wal-g functionality
test_mock_walg() {
    echof "Testing mock wal-g functionality"
    
    local mock_walg="$SCRIPT_DIR/scripts/mock-wal-g.sh"
    if [[ -f "$mock_walg" && -x "$mock_walg" ]]; then
        # Test basic commands
        if "$mock_walg" --help >/dev/null 2>&1; then
            pass "Mock wal-g --help works"
        else
            warn "Mock wal-g --help failed"
        fi
        
        if "$mock_walg" --version >/dev/null 2>&1; then
            pass "Mock wal-g --version works"
        else
            warn "Mock wal-g --version failed"
        fi
        
        # Test backup-list (should work even if empty)
        if "$mock_walg" backup-list >/dev/null 2>&1; then
            pass "Mock wal-g backup-list works"
        else
            warn "Mock wal-g backup-list failed"
        fi
    else
        warn "Mock wal-g script not found or not executable"
    fi
}

# Test 7: Documentation
test_documentation() {
    echof "Testing documentation"
    
    local readme="$SCRIPT_DIR/README.org"
    if [[ -f "$readme" ]]; then
        if grep -q "WAL-G" "$readme"; then
            pass "README.org mentions WAL-G"
        else
            warn "README.org missing WAL-G documentation"
        fi
        
        if grep -q "test-walg-e2e.sh" "$readme"; then
            pass "README.org mentions E2E testing"
        else
            warn "README.org missing E2E testing documentation"
        fi
    else
        warn "README.org not found"
    fi
    
    local test_doc="$SCRIPT_DIR/docs/WAL-G-TESTING.md"
    if [[ -f "$test_doc" ]]; then
        pass "WAL-G testing documentation exists"
    else
        warn "WAL-G testing documentation missing"
    fi
}

# Main validation function
main() {
    echof "WAL-G Feature Validation"
    echo "This script validates the WAL-G setup without requiring running containers."
    echo ""
    
    cd "$SCRIPT_DIR"
    
    test_configuration_files
    echo ""
    
    test_script_availability  
    echo ""
    
    test_environment_config
    echo ""
    
    test_ssh_setup
    echo ""
    
    test_dockerfile_structure
    echo ""
    
    test_mock_walg
    echo ""
    
    test_documentation
    echo ""
    
    echof "Validation Complete"
    echo ""
    echo "Next steps:"
    echo "1. Run offline tests: ./test/test-offline-e2e.sh"
    echo "2. Setup local SSH server: ./scripts/setup-local-ssh.sh"
    echo "3. Run full E2E tests: ./test/test-walg-e2e.sh"
    echo ""
    echo "For more information, see: docs/WAL-G-TESTING.md"
}

# Run main function
main "$@"