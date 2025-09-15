#!/usr/bin/env bash
# Shared test helper functions to avoid duplication across test scripts

# Output formatting functions
echof() { printf "%s\n" "$*"; }
pass() { echo "PASS: $*"; }
skip() { echo "SKIP: $*"; }
warn() { echo "WARN: $*"; }
die() { echo "FAIL: $*" >&2; exit 1; }

# Check if a command exists
check_command() {
  command -v "$1" >/dev/null 2>&1 || die "Required command '$1' not found on PATH"
}

# Wait for container to be ready
wait_for_container() {
    local container_id="$1"
    local timeout="${2:-60}"
    local counter=0
    
    while [ $counter -lt $timeout ]; do
        if docker exec "$container_id" pg_isready >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
        counter=$((counter + 1))
    done
    return 1
}

# Get container ID by service name
get_container_id() {
    local service_name="$1"
    docker compose ps -q "$service_name" 2>/dev/null || echo ""
}

# Check if we're in a specific backup mode
is_backup_mode() {
    local mode="$1"
    local env_file="${2:-.env}"
    
    if [[ -f "$env_file" ]]; then
        local current_mode=$(grep "^BACKUP_MODE=" "$env_file" | cut -d'=' -f2 || echo "sql")
        [[ "$current_mode" == "$mode" ]]
    else
        [[ "${BACKUP_MODE:-sql}" == "$mode" ]]
    fi
}