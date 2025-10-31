#!/usr/bin/env bash
set -euo pipefail

# PgBouncer connectivity and functionality tests
# Tests that PgBouncer is properly configured and can proxy connections to PostgreSQL
# Note: PgBouncer runs within the PostgreSQL container, not as a separate service

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$REPO_DIR/.env"
COMPOSE_CMD="docker compose"
POSTGRES_SERVICE_NAME="postgres"

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

# Load environment variables
if [[ -f "$ENV_FILE" ]]; then
    set -o allexport
    source "$ENV_FILE"
    set +o allexport
fi

POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-}"
POSTGRES_DB="${POSTGRES_DB:-postgres}"
PGBOUNCER_PORT="${PGBOUNCER_PORT:-6432}"
ENABLE_PGBOUNCER="${ENABLE_PGBOUNCER:-0}"

# Get container IDs
get_container_ids() {
    POSTGRES_CONTAINER_ID=$($COMPOSE_CMD ps -q "$POSTGRES_SERVICE_NAME" 2>/dev/null || true)
    
    if [[ -z "$POSTGRES_CONTAINER_ID" ]]; then
        die "Postgres container not found"
    fi
}

# Test 1: PgBouncer process exists and is running
test_pgbouncer_process_running() {
    echof "Testing PgBouncer process status"
    
    # Check if pgbouncer binary exists
    if ! docker exec "$POSTGRES_CONTAINER_ID" which pgbouncer >/dev/null 2>&1; then
        skip "PgBouncer binary not found in PostgreSQL container"
        return 1
    fi
    
    pass "PgBouncer binary is installed"
    
    # Check if PgBouncer process is running
    if docker exec "$POSTGRES_CONTAINER_ID" pgrep -x pgbouncer >/dev/null 2>&1; then
        pass "PgBouncer process is running"
        return 0
    else
        skip "PgBouncer process is not running (ENABLE_PGBOUNCER may not be set to 1)"
        return 1
    fi
}

# Test 2: PgBouncer is listening on the configured port
test_pgbouncer_listening() {
    echof "Testing PgBouncer port listening"
    
    # Give PgBouncer a moment to fully start if it just launched
    sleep 2
    
    # Check if PgBouncer is listening on the expected port
    # Instead of using netstat/ss (which may not be available), try to connect
    local max_attempts=10
    local attempt=0
    
    export PGPASSWORD="${POSTGRES_PASSWORD}"
    
    while ((attempt < max_attempts)); do
        # Try to connect to PgBouncer admin console as a port check
        if docker exec "$POSTGRES_CONTAINER_ID" bash -c "PGPASSWORD='${POSTGRES_PASSWORD}' psql -h localhost -p ${PGBOUNCER_PORT} -U ${POSTGRES_USER} -d pgbouncer -c 'SHOW VERSION;'" >/dev/null 2>&1; then
            pass "PgBouncer is listening on port ${PGBOUNCER_PORT}"
            unset PGPASSWORD
            return 0
        fi
        
        # Fallback: check with netstat/ss if available
        if docker exec "$POSTGRES_CONTAINER_ID" netstat -ln 2>/dev/null | grep -q ":${PGBOUNCER_PORT} " || \
           docker exec "$POSTGRES_CONTAINER_ID" ss -ln 2>/dev/null | grep -q ":${PGBOUNCER_PORT} "; then
            pass "PgBouncer is listening on port ${PGBOUNCER_PORT} (via netstat/ss)"
            unset PGPASSWORD
            return 0
        fi
        
        ((attempt++))
        sleep 1
    done
    
    unset PGPASSWORD
    skip "PgBouncer is not listening on port ${PGBOUNCER_PORT} after ${max_attempts} attempts"
    return 1
}

# Test 3: Connect to PostgreSQL through PgBouncer
test_pgbouncer_connection() {
    echof "Testing PostgreSQL connection through PgBouncer"
    
    # Try to connect through PgBouncer (localhost since it's in the same container)
    if docker exec "$POSTGRES_CONTAINER_ID" bash -c "PGPASSWORD='${POSTGRES_PASSWORD}' psql -h localhost -p ${PGBOUNCER_PORT} -U ${POSTGRES_USER} -d ${POSTGRES_DB} -c 'SELECT 1;'" >/dev/null 2>&1; then
        pass "Successfully connected to PostgreSQL through PgBouncer"
    else
        skip "Failed to connect to PostgreSQL through PgBouncer (may not be configured)"
        return 1
    fi
    
    return 0
}

# Test 4: Execute basic DDL through PgBouncer
test_pgbouncer_ddl_operations() {
    echof "Testing DDL operations through PgBouncer"
    
    # Create a test table through PgBouncer
    if docker exec "$POSTGRES_CONTAINER_ID" bash -c "PGPASSWORD='${POSTGRES_PASSWORD}' psql -h localhost -p ${PGBOUNCER_PORT} -U ${POSTGRES_USER} -d ${POSTGRES_DB} -c 'CREATE TABLE IF NOT EXISTS pgbouncer_test (id SERIAL PRIMARY KEY, test_data TEXT);'" >/dev/null 2>&1; then
        pass "Created test table through PgBouncer"
    else
        skip "Failed to create test table through PgBouncer"
        return 1
    fi
    
    # Insert data through PgBouncer
    if docker exec "$POSTGRES_CONTAINER_ID" bash -c "PGPASSWORD='${POSTGRES_PASSWORD}' psql -h localhost -p ${PGBOUNCER_PORT} -U ${POSTGRES_USER} -d ${POSTGRES_DB} -c \"INSERT INTO pgbouncer_test (test_data) VALUES ('test_via_pgbouncer');\"" >/dev/null 2>&1; then
        pass "Inserted data through PgBouncer"
    else
        skip "Failed to insert data through PgBouncer"
        return 1
    fi
    
    # Query data through PgBouncer
    if docker exec "$POSTGRES_CONTAINER_ID" bash -c "PGPASSWORD='${POSTGRES_PASSWORD}' psql -h localhost -p ${PGBOUNCER_PORT} -U ${POSTGRES_USER} -d ${POSTGRES_DB} -t -A -c 'SELECT test_data FROM pgbouncer_test WHERE test_data = '\''test_via_pgbouncer'\'';'" 2>/dev/null | grep -q "test_via_pgbouncer"; then
        pass "Successfully queried data through PgBouncer"
    else
        skip "Failed to query data through PgBouncer"
        return 1
    fi
    
    # Clean up test table
    docker exec "$POSTGRES_CONTAINER_ID" bash -c "PGPASSWORD='${POSTGRES_PASSWORD}' psql -h localhost -p ${PGBOUNCER_PORT} -U ${POSTGRES_USER} -d ${POSTGRES_DB} -c 'DROP TABLE IF EXISTS pgbouncer_test;'" >/dev/null 2>&1 || true
    pass "Cleaned up test table"
    
    return 0
}

# Test 5: Verify PgBouncer admin console accessibility
test_pgbouncer_admin_console() {
    echof "Testing PgBouncer admin console"
    
    # Try to access pgbouncer admin console
    if docker exec "$POSTGRES_CONTAINER_ID" bash -c "PGPASSWORD='${POSTGRES_PASSWORD}' psql -h localhost -p ${PGBOUNCER_PORT} -U ${POSTGRES_USER} -d pgbouncer -c 'SHOW POOLS;'" >/dev/null 2>&1; then
        pass "Successfully accessed PgBouncer admin console"
        
        # Show pool statistics for debugging
        echof "PgBouncer pool statistics:"
        docker exec "$POSTGRES_CONTAINER_ID" bash -c "PGPASSWORD='${POSTGRES_PASSWORD}' psql -h localhost -p ${PGBOUNCER_PORT} -U ${POSTGRES_USER} -d pgbouncer -c 'SHOW POOLS;'" 2>/dev/null || true
    else
        skip "PgBouncer admin console not accessible (may require admin_users configuration)"
    fi
}

# Test 6: Check PgBouncer configuration
test_pgbouncer_configuration() {
    echof "Testing PgBouncer configuration"
    
    # Check if config file exists
    if docker exec "$POSTGRES_CONTAINER_ID" test -f /etc/pgbouncer/pgbouncer.ini; then
        pass "PgBouncer configuration file exists"
        
        # Show relevant config sections
        echof "PgBouncer configuration excerpt:"
        docker exec "$POSTGRES_CONTAINER_ID" grep -E "^(listen_port|pool_mode|auth_type|max_client_conn)" /etc/pgbouncer/pgbouncer.ini 2>/dev/null || true
    else
        skip "PgBouncer configuration file not found at /etc/pgbouncer/pgbouncer.ini"
    fi
}

# Test 7: Verify connection pooling is working
test_pgbouncer_pooling() {
    echof "Testing PgBouncer connection pooling"
    
    # Make multiple connections through PgBouncer
    local success_count=0
    for i in {1..5}; do
        if docker exec "$POSTGRES_CONTAINER_ID" bash -c "PGPASSWORD='${POSTGRES_PASSWORD}' psql -h localhost -p ${PGBOUNCER_PORT} -U ${POSTGRES_USER} -d ${POSTGRES_DB} -c 'SELECT pg_sleep(0.1);'" >/dev/null 2>&1; then
            ((success_count++))
        fi
    done
    
    if ((success_count >= 5)); then
        pass "Connection pooling test: ${success_count}/5 connections successful"
    else
        skip "Connection pooling test: only ${success_count}/5 connections successful"
        return 1
    fi
    
    return 0
}

# Main test execution
main() {
    echof "Starting PgBouncer functionality tests"
    
    # Change to repository directory
    cd "$REPO_DIR"
    
    # Check if PgBouncer is enabled
    if [[ "$ENABLE_PGBOUNCER" != "1" ]]; then
        echof "ENABLE_PGBOUNCER is not set to 1 (currently: ${ENABLE_PGBOUNCER})"
        echof "PgBouncer tests will be skipped"
        skip "Set ENABLE_PGBOUNCER=1 in .env to run these tests"
        exit 0
    fi
    
    # Get container information
    get_container_ids
    
    echof "Container ID: postgres=$POSTGRES_CONTAINER_ID"
    
    # Run tests in sequence
    local test_failed=0
    
    test_pgbouncer_process_running || test_failed=1
    echo ""
    
    if [[ $test_failed -eq 0 ]]; then
        test_pgbouncer_listening || test_failed=1
        echo ""
    fi
    
    if [[ $test_failed -eq 0 ]]; then
        test_pgbouncer_connection || test_failed=1
        echo ""
    fi
    
    if [[ $test_failed -eq 0 ]]; then
        test_pgbouncer_ddl_operations || test_failed=1
        echo ""
    fi
    
    if [[ $test_failed -eq 0 ]]; then
        test_pgbouncer_admin_console || true  # Don't fail on this one
        echo ""
    fi
    
    if [[ $test_failed -eq 0 ]]; then
        test_pgbouncer_configuration || true  # Don't fail on this one
        echo ""
    fi
    
    if [[ $test_failed -eq 0 ]]; then
        test_pgbouncer_pooling || test_failed=1
        echo ""
    fi
    
    echof "PgBouncer functionality tests completed"
    
    if [[ $test_failed -eq 1 ]]; then
        die "Some PgBouncer tests failed"
    fi
}

# Only run main if script is executed directly (not sourced)
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
