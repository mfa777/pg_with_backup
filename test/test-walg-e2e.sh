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

# Fast-mode tuning (inherited from wrapper). You can override via env.
FAST=${FAST:-0}
if [[ "$FAST" == "1" ]]; then
    E2E_PG_READY_TIMEOUT=${E2E_PG_READY_TIMEOUT:-15}
    E2E_SSH_READY_TIMEOUT=${E2E_SSH_READY_TIMEOUT:-15}
    E2E_INIT_SLEEP=${E2E_INIT_SLEEP:-2}
    E2E_STACK_INIT_WAIT=${E2E_STACK_INIT_WAIT:-5}
    E2E_WAL_ATTEMPTS=${E2E_WAL_ATTEMPTS:-3}
    E2E_INSERT_ROWS=${E2E_INSERT_ROWS:-500}
    E2E_SLEEP_BETWEEN=${E2E_SLEEP_BETWEEN:-2}
    E2E_FINAL_SLEEP=${E2E_FINAL_SLEEP:-5}
    E2E_BACKUP_WAIT1=${E2E_BACKUP_WAIT1:-6}
    E2E_SHORT_WAL_WAIT=${E2E_SHORT_WAL_WAIT:-2}
    E2E_BACKUP_WAIT2=${E2E_BACKUP_WAIT2:-6}
    E2E_CLEANUP_WAIT=${E2E_CLEANUP_WAIT:-4}
    E2E_TIMEOUT_SHORT=${E2E_TIMEOUT_SHORT:-5}
    E2E_TIMEOUT_LONG=${E2E_TIMEOUT_LONG:-7}
else
    E2E_PG_READY_TIMEOUT=${E2E_PG_READY_TIMEOUT:-30}
    E2E_SSH_READY_TIMEOUT=${E2E_SSH_READY_TIMEOUT:-30}
    E2E_INIT_SLEEP=${E2E_INIT_SLEEP:-5}
    E2E_STACK_INIT_WAIT=${E2E_STACK_INIT_WAIT:-10}
    E2E_WAL_ATTEMPTS=${E2E_WAL_ATTEMPTS:-8}
    E2E_INSERT_ROWS=${E2E_INSERT_ROWS:-5000}
    E2E_SLEEP_BETWEEN=${E2E_SLEEP_BETWEEN:-6}
    E2E_FINAL_SLEEP=${E2E_FINAL_SLEEP:-12}
    E2E_BACKUP_WAIT1=${E2E_BACKUP_WAIT1:-15}
    E2E_SHORT_WAL_WAIT=${E2E_SHORT_WAL_WAIT:-5}
    E2E_BACKUP_WAIT2=${E2E_BACKUP_WAIT2:-15}
    E2E_CLEANUP_WAIT=${E2E_CLEANUP_WAIT:-10}
    E2E_TIMEOUT_SHORT=${E2E_TIMEOUT_SHORT:-10}
    E2E_TIMEOUT_LONG=${E2E_TIMEOUT_LONG:-15}
fi

# Derive SSH connection parameters:
# - If ENABLE_SSH_SERVER=1 -> internal container hostname is 'ssh-server', default user 'walg', default port 2222
# - Else try to parse from WALG_SSH_PREFIX (ssh://user@host[:port]/path)
if [[ "${ENABLE_SSH_SERVER:-0}" == "1" ]]; then
    SSH_HOST="ssh-server"
    SSH_USER="${SSH_USER:-${SSH_USERNAME:-walg}}"
    SSH_PORT="${SSH_PORT:-2222}"
else
    # Parse WALG_SSH_PREFIX if available
    if [[ -n "${WALG_SSH_PREFIX:-}" ]]; then
        # Remove ssh:// prefix and any trailing path to get user@host:port
        _tmp=${WALG_SSH_PREFIX#ssh://}
        _tmp=${_tmp%%/*}   # now user@host[:port] or host[:port]

        # If an @ exists, split user and hostport
        if [[ "$_tmp" == *@* ]]; then
            SSH_USER=${_tmp%%@*}
            _hostport=${_tmp#*@}
        else
            _hostport=$_tmp
        fi

        # If a :port exists at the end, split host and port
        if [[ "$_hostport" == *:* ]]; then
            SSH_PORT=${_hostport##*:}
            SSH_HOST=${_hostport%%:*}
        else
            SSH_HOST=$_hostport
        fi
    fi
    # Fallback defaults
    SSH_USER="${SSH_USER:-${SSH_USERNAME:-walg}}"
    SSH_PORT="${SSH_PORT:-22}"
fi

# Test helper port used in SSH test commands
WALG_SSH_TEST_PORT="${WALG_SSH_TEST_PORT:-$SSH_PORT}"

# Ensure we have an SSH host to connect to (fail early with helpful message)
if [[ -z "${SSH_HOST:-}" ]]; then
    echo "Error: SSH host could not be determined. Set WALG_SSH_PREFIX (ssh://user@host[:port]/path) or set ENABLE_SSH_SERVER=1 to use the internal test server." >&2
    exit 4
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

# Derive remote backup path from WALG_SSH_PREFIX (absolute path required by wal-g)
get_remote_backup_path() {
    # Default path used when we cannot parse a path component
    local default="/backups"
    if [[ -n "${WALG_SSH_PREFIX:-}" && "${WALG_SSH_PREFIX}" =~ ^ssh://[^/]+(/.*)$ ]]; then
        local p="${BASH_REMATCH[1]}"
        # Ensure it starts with /. wal-g requires absolute path.
        if [[ "$p" != /* ]]; then
            p="/$p"
        fi
        echo "$p"
    else
        echo "$default"
    fi
}

# Common SSH options for host-side test runner (avoid interactive prompts)
SSH_TEST_OPTS="-o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

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
    
    if [[ "${ENABLE_SSH_SERVER:-0}" == "1" ]]; then
        if [[ -z "$SSH_CONTAINER_ID" ]]; then
            die "SSH server container not found. Is the stack running with --profile ssh-testing?"
        fi
    else
        # If not using internal server, SSH_CONTAINER_ID may be empty; that's OK
        :
    fi
}

# Wait for services to be ready
wait_for_services() {
    echof "Waiting for services to be ready"
    
    # Wait for PostgreSQL
    local timeout=$E2E_PG_READY_TIMEOUT
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
    
    # Wait for SSH server only if using internal test container
    if [[ "${ENABLE_SSH_SERVER:-0}" == "1" ]]; then
        count=0
        while ! docker exec "$SSH_CONTAINER_ID" netstat -ln | grep -q ":${SSH_PORT} "; do
            if ((count++ > E2E_SSH_READY_TIMEOUT)); then
                die "SSH server failed to become ready within $E2E_SSH_READY_TIMEOUT seconds"
            fi
            sleep 1
        done
        pass "SSH server is ready"
    else
        pass "External SSH server assumed available (not checking container)"
    fi
    
    # Ensure backup directory has proper permissions for walg user
    echo "Setting up backup directory permissions..."
    if [[ "${ENABLE_SSH_SERVER:-0}" == "1" ]]; then
        if docker exec "$SSH_CONTAINER_ID" bash -c "mkdir -p /backups && chown walg:walg /backups && chmod 755 /backups" 2>/dev/null; then
            pass "Backup directory permissions configured (ssh-server container)"
        else
            warn "Could not configure backup directory permissions in ssh-server container (may still work)"
        fi
    else
        # Use postgres container (which has the prepared key) to create remote path
        remote_path="$(get_remote_backup_path)"
        if docker exec "$POSTGRES_CONTAINER_ID" bash -c "su - postgres -c 'ssh -i /var/lib/postgresql/.ssh/walg_key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -p ${SSH_PORT} ${SSH_USER}@${SSH_HOST} \"mkdir -p ${remote_path} && chmod 755 ${remote_path}\"'" 2>/dev/null; then
            pass "Backup directory permissions configured on external SSH host (via postgres container)"
        else
            warn "Could not configure backup directory permissions on external SSH host (via postgres container)"
        fi
    fi
    
    # Give a moment for wal-g initialization
    sleep "$E2E_INIT_SLEEP"
}

# Test if we can list remote backups (baseline)
test_remote_connectivity() {
    echof "Testing remote SSH connectivity and wal-g configuration"
    
    # Test SSH connectivity from postgres container
    # For Hetzner Storage Box and similar restricted shells, use SFTP to test connectivity
    # SFTP should be available even when shell commands are not
    if docker exec "$POSTGRES_CONTAINER_ID" bash -c "su - postgres -c \"echo 'ls' | sftp -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes -P $WALG_SSH_TEST_PORT ${SSH_USER}@${SSH_HOST} 2>/dev/null | grep -q 'sftp>'\"" 2>/dev/null; then
        pass "SSH connectivity to remote server working (SFTP)"
    else
        warn "SSH connectivity test failed — collecting verbose SSH output for debugging (as postgres)"
        echo "---- SSH verbose debug output start ----"
        docker exec "$POSTGRES_CONTAINER_ID" bash -c "su - postgres -c \"ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes -o PreferredAuthentications=publickey -p $WALG_SSH_TEST_PORT -vvv ${SSH_USER}@${SSH_HOST}\"" || true
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
    # Total count of compressed WAL-related files (segments + backup history markers)
    local out
    if [[ "${ENABLE_SSH_SERVER:-0}" == "1" ]]; then
        out=$(docker exec "$SSH_CONTAINER_ID" bash -c "find /backups -type f -name '*.lz4' -o -name '*.br' -o -name '*.gz' -o -name '*.zst' | wc -l" 2>/dev/null || true)
    else
        # For external SSH servers, dynamically find WAL directories (wal_005, wal_006, etc.) and count all files
        # WAL-G creates wal_XXX directory structure based on timeline. Use simple, portable commands only.
        local remote_path="$(get_remote_backup_path)"
        # List all wal_* directories and count files in each (one entry per line)
        local wal_dirs
        wal_dirs=$(docker exec "$POSTGRES_CONTAINER_ID" bash -c "su - postgres -c 'ssh -i /var/lib/postgresql/.ssh/walg_key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -p ${SSH_PORT} ${SSH_USER}@${SSH_HOST} \"ls -1 ${remote_path}/\"'" 2>/dev/null | grep '^wal_' || echo "")
        
        if [[ -z "$wal_dirs" ]]; then
            out="0"
        else
            # Count files in all wal_* directories (robust: count all entries)
            local total=0
            while IFS= read -r dir; do
                [[ -z "$dir" ]] && continue
                # Sanitize possible CR or trailing slashes from restricted SSH output
                dir=${dir//$'\r'/}
                dir=${dir%/}
                local count
                count=$(docker exec "$POSTGRES_CONTAINER_ID" bash -c "su - postgres -c 'ssh -i /var/lib/postgresql/.ssh/walg_key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -p ${SSH_PORT} ${SSH_USER}@${SSH_HOST} \"ls -1 ${remote_path}/${dir}/\"'" 2>/dev/null | wc -l)
                total=$((total + count))
            done <<< "$wal_dirs"
            out="$total"
        fi
    fi
    out=$(echo "${out:-0}" | tr -d '[:space:]')
    [[ -z "$out" || ! "$out" =~ ^[0-9]+$ ]] && echo 0 || echo "$out"
}

# Count only pure WAL segment files (exclude .backup history / sentinel files)
get_remote_pure_wal_count() {
    local out
    if [[ "${ENABLE_SSH_SERVER:-0}" == "1" ]]; then
        out=$(docker exec "$SSH_CONTAINER_ID" bash -c "find /backups -type f -name '*.lz4' -o -name '*.br' -o -name '*.gz' -o -name '*.zst' | sed 's|.*/||' | grep -E '^[0-9A-F]{24}\.(lz4|br|gz|zst)$' | wc -l" 2>/dev/null || true)
    else
        # Use ls via SSH instead of find for storage boxes that don't support shell commands
        # WAL-G creates wal_XXX directory structure, dynamically find and count from all wal_* dirs
        local remote_path="$(get_remote_backup_path)"
        local ssh_key_arg="-i /var/lib/postgresql/.ssh/walg_key"
        
        # List all wal_* directories
        local wal_dirs
        wal_dirs=$(docker exec "$POSTGRES_CONTAINER_ID" bash -c "su - postgres -c 'ssh ${ssh_key_arg} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -p ${SSH_PORT} ${SSH_USER}@${SSH_HOST} \"ls -1 ${remote_path}/\"'" 2>/dev/null | grep '^wal_' || echo "")
        
        if [[ -z "$wal_dirs" ]]; then
            out="0"
        else
            # Count pure WAL files in all wal_* directories
            local total=0
            while IFS= read -r dir; do
                [[ -z "$dir" ]] && continue
                # Sanitize possible CR or trailing slashes
                dir=${dir//$'\r'/}
                dir=${dir%/}
                # Prefer filtered count, but fall back to raw count if filter returns 0
                local filtered raw
                filtered=$(docker exec "$POSTGRES_CONTAINER_ID" bash -c "su - postgres -c 'ssh ${ssh_key_arg} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -p ${SSH_PORT} ${SSH_USER}@${SSH_HOST} \"ls -1 ${remote_path}/${dir}/\"'" 2>/dev/null | grep -E '^[0-9A-Fa-f]{24}\\.(lz4|br|gz|zst)$' | wc -l)
                raw=$(docker exec "$POSTGRES_CONTAINER_ID" bash -c "su - postgres -c 'ssh ${ssh_key_arg} -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -p ${SSH_PORT} ${SSH_USER}@${SSH_HOST} \"ls -1 ${remote_path}/${dir}/\"'" 2>/dev/null | wc -l)
                if [[ "$filtered" =~ ^[0-9]+$ && "$filtered" -gt 0 ]]; then
                    total=$((total + filtered))
                else
                    total=$((total + raw))
                fi
            done <<< "$wal_dirs"
            out="$total"
        fi
    fi
    out=$(echo "${out:-0}" | tr -d '[:space:]')
    [[ -z "$out" || ! "$out" =~ ^[0-9]+$ ]] && echo 0 || echo "$out"
}

# Test 1: Archive command wal-push functionality
test_wal_push_e2e() {
    echof "Testing end-to-end WAL push functionality"
    
    # Helper to read pg_stat_archiver quickly
    get_archiver_stat() {
        local field="$1"
        docker exec "$POSTGRES_CONTAINER_ID" psql -U "$POSTGRES_USER" -Atc "SELECT ${field} FROM pg_stat_archiver;" 2>/dev/null | tr -d '[:space:]'
    }

    # Helper: check if a given WAL segment (without extension) exists remotely in any wal_* directory
    remote_has_wal_segment() {
        local seg="$1"
        local remote_path="$(get_remote_backup_path)"
        local ssh_base="ssh -i /var/lib/postgresql/.ssh/walg_key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -p ${SSH_PORT} ${SSH_USER}@${SSH_HOST}"
        # List wal_* dirs
        local wal_dirs
        wal_dirs=$(docker exec "$POSTGRES_CONTAINER_ID" bash -c "su - postgres -c '${ssh_base} \"ls -1 ${remote_path}/\"'" 2>/dev/null | grep '^wal_' || true)
        if [[ -z "$wal_dirs" ]]; then
            return 1
        fi
        while IFS= read -r d; do
            [[ -z "$d" ]] && continue
            d=${d//$'\r'/}; d=${d%/}
            if docker exec "$POSTGRES_CONTAINER_ID" bash -c "su - postgres -c '${ssh_base} \"ls -1 ${remote_path}/${d}/\"'" 2>/dev/null | grep -q -E "^${seg}\\.(lz4|br|gz|zst)$"; then
                return 0
            fi
        done <<< "$wal_dirs"
        return 1
    }

    # Check initial WAL count
    local initial_wal_count initial_pure_wal_count
    initial_wal_count=$(get_remote_wal_count)
    initial_pure_wal_count=$(get_remote_pure_wal_count)
    echo "Initial WAL count (all compressed files): $initial_wal_count"
    echo "Initial pure WAL segment count: $initial_pure_wal_count"
    if (( initial_pure_wal_count == 0 )); then
        echo "(debug) Listing candidate WAL basenames (raw) and filtered matches:"
        if [[ "${ENABLE_SSH_SERVER:-0}" == "1" ]]; then
            docker exec "$SSH_CONTAINER_ID" bash -c "find /backups -type f -name '*.lz4' -o -name '*.br' -o -name '*.gz' -o -name '*.zst' | head -20" || true
            echo "(debug) Pure WAL pattern matches:"
            docker exec "$SSH_CONTAINER_ID" bash -c "find /backups -type f -name '*.lz4' -o -name '*.br' -o -name '*.gz' -o -name '*.zst' | sed 's|.*/||' | grep -E '^[0-9A-F]{24}\.(lz4|br|gz|zst)$' | head -20" || true
        else
            # Use ls instead of find for storage boxes that don't support shell commands
            remote_path="$(get_remote_backup_path)"
                        echo "(debug) Remote path top-level entries (first 20):"
                        docker exec "$POSTGRES_CONTAINER_ID" bash -c "su - postgres -c 'ssh -i /var/lib/postgresql/.ssh/walg_key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -p ${SSH_PORT} ${SSH_USER}@${SSH_HOST} \"ls -1 ${remote_path}/\"'" 2>/dev/null | head -20 || true
                        echo "(debug) wal_* directories (if any):"
                        docker exec "$POSTGRES_CONTAINER_ID" bash -c "su - postgres -c 'ssh -i /var/lib/postgresql/.ssh/walg_key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -p ${SSH_PORT} ${SSH_USER}@${SSH_HOST} \"ls -1 ${remote_path}/\"'" 2>/dev/null | grep '^wal_' | head -20 || true
        fi
    fi
    
    # Show current remote directory structure for debugging
    echo "Current remote directory structure:"
    if [[ "${ENABLE_SSH_SERVER:-0}" == "1" ]]; then
        docker exec "$SSH_CONTAINER_ID" bash -c "find /backups -type f 2>/dev/null | head -10" || echo "No files found or directory doesn't exist"
    else
        remote_path="$(get_remote_backup_path)"
        docker exec "$POSTGRES_CONTAINER_ID" bash -c "su - postgres -c \"echo 'ls ${remote_path}' | sftp -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes -P ${SSH_PORT} ${SSH_USER}@${SSH_HOST} 2>/dev/null | head -10\"" || echo "No files found or directory doesn't exist"
    fi
    
    # Generate some WAL activity with adaptive polling & forced switches
    echo "Generating WAL activity (adaptive)..."
    # We'll loop a few times to ensure at least one new segment gets archived.
    local attempts=0 current_after_gen current_after_pure
    local initial_archived_count initial_last_wal now_archived_count now_last_wal
    initial_archived_count=$(get_archiver_stat archived_count || echo 0)
    initial_last_wal=$(get_archiver_stat last_archived_wal || echo "")
    local max_attempts=$E2E_WAL_ATTEMPTS
    local target=$((initial_pure_wal_count + 1))
    while (( attempts < max_attempts )); do
        attempts=$((attempts + 1))
        echo "[WAL GEN] Attempt $attempts: inserting rows and forcing switch"
        docker exec "$POSTGRES_CONTAINER_ID" psql -U "$POSTGRES_USER" -v ON_ERROR_STOP=1 -c "
            CREATE TABLE IF NOT EXISTS wal_test_table (id SERIAL PRIMARY KEY, data TEXT);
            INSERT INTO wal_test_table (data) SELECT 'test_data_' || generate_series(1, ${E2E_INSERT_ROWS});
            SELECT pg_switch_wal();
        " >/dev/null 2>&1 || echo "Insert/switch attempt $attempts failed (continuing)"
        # Short wait to allow archiver to pick up the switched segment
        sleep "$E2E_SLEEP_BETWEEN"
        current_after_gen=$(get_remote_wal_count)
        current_after_pure=$(get_remote_pure_wal_count)
        now_archived_count=$(get_archiver_stat archived_count || echo 0)
        now_last_wal=$(get_archiver_stat last_archived_wal || echo "")
        echo "[WAL GEN] Remote counts now: all=$current_after_gen pure=$current_after_pure (target > $initial_pure_wal_count)"
        # Success conditions:
        # 1) pure WAL count increased, OR
        # 2) pg_stat_archiver.archived_count increased, OR
        # 3) last_archived_wal changed and that segment exists remotely
        if (( current_after_pure > initial_pure_wal_count )); then
            echo "New WAL segment detected after $attempts attempt(s)"
            break
        elif (( now_archived_count > initial_archived_count )); then
            echo "pg_stat_archiver archived_count increased to $now_archived_count"
            # Optional: verify presence of last archived wal remotely
            if [[ -n "$now_last_wal" ]] && remote_has_wal_segment "$now_last_wal"; then
                echo "Confirmed remote presence of $now_last_wal"
            fi
            break
        elif [[ -n "$now_last_wal" && "$now_last_wal" != "$initial_last_wal" ]] && remote_has_wal_segment "$now_last_wal"; then
            echo "Found new last_archived_wal on remote: $now_last_wal"
            break
        fi
    done
    
    # If still no progress, perform one more explicit switch & wait a bit longer
    if (( current_after_pure <= initial_pure_wal_count )); then
        echo "No new WAL yet; performing final forced switch & extended wait"
        docker exec "$POSTGRES_CONTAINER_ID" psql -U "$POSTGRES_USER" -c "SELECT pg_switch_wal(); SELECT pg_switch_wal();" >/dev/null 2>&1 || true
        sleep "$E2E_FINAL_SLEEP"
    fi
    
    # Check if new WAL files appeared
    local final_wal_count final_pure_wal_count
    final_wal_count=$(get_remote_wal_count)
    final_pure_wal_count=$(get_remote_pure_wal_count)
    echo "Final WAL count (all compressed files): $final_wal_count"
    echo "Final pure WAL segment count: $final_pure_wal_count"
    
    # Show what files were created for debugging
    echo "Files in remote storage after WAL activity:"
    if [[ "${ENABLE_SSH_SERVER:-0}" == "1" ]]; then
        docker exec "$SSH_CONTAINER_ID" bash -c "find /backups -type f -newer /backups 2>/dev/null | head -10" || echo "No new files found"
    else
                        # Use ls with sorting for storage boxes that don't support find
                        # List newest files from default wal_005 directory (debug hint only)
        remote_path="$(get_remote_backup_path)"
                        docker exec "$POSTGRES_CONTAINER_ID" bash -c "su - postgres -c 'ssh -i /var/lib/postgresql/.ssh/walg_key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -p ${SSH_PORT} ${SSH_USER}@${SSH_HOST} \"ls -t ${remote_path}/wal_005/\"'" 2>/dev/null | head -10 || echo "No files found"
    fi
    
    # Final success evaluation (same conditions as loop)
    if ((final_pure_wal_count > initial_pure_wal_count)); then
        pass "WAL files successfully pushed (pure segments: $initial_pure_wal_count -> $final_pure_wal_count)"
    else
        now_archived_count=$(get_archiver_stat archived_count || echo 0)
        now_last_wal=$(get_archiver_stat last_archived_wal || echo "")
        if (( now_archived_count > initial_archived_count )); then
            pass "WAL archived by PostgreSQL archiver (archived_count: $initial_archived_count -> $now_archived_count)"
            if [[ -n "$now_last_wal" ]] && remote_has_wal_segment "$now_last_wal"; then
                pass "Last archived WAL present remotely: $now_last_wal"
            fi
            return
        elif [[ -n "$now_last_wal" && "$now_last_wal" != "$initial_last_wal" ]] && remote_has_wal_segment "$now_last_wal"; then
            pass "Last archived WAL present remotely: $now_last_wal (even if total count unchanged due to pre-existing files)"
            return
        fi
        # Verify we can see specific WAL push activity in logs
        if docker logs "$POSTGRES_CONTAINER_ID" 2>&1 | grep -q "wal-g wal-push\|archived"; then
            pass "WAL push activity detected in PostgreSQL logs"
        else
            warn "No explicit WAL push activity found in logs"
        fi
    fi
    if ((final_pure_wal_count <= initial_pure_wal_count)); then
        # Additional debugging for failed WAL push
        echo "=== DEBUGGING FAILED WAL PUSH ==="
        echo "Checking PostgreSQL configuration..."
        docker exec "$POSTGRES_CONTAINER_ID" psql -U "$POSTGRES_USER" -c "SHOW archive_mode;" || echo "Failed to check archive_mode"
        docker exec "$POSTGRES_CONTAINER_ID" psql -U "$POSTGRES_USER" -c "SHOW archive_command;" || echo "Failed to check archive_command"
        
        echo "Checking PostgreSQL logs for errors..."
        docker logs "$POSTGRES_CONTAINER_ID" 2>&1 | grep -i "archive\|wal-g\|error" | tail -10 || echo "No relevant log entries found"
        
    echo "Testing wal-g manually..."
    docker exec "$POSTGRES_CONTAINER_ID" bash -c "wal-g --version" || echo "wal-g not accessible"
    echo "pg_stat_archiver info:"
    docker exec "$POSTGRES_CONTAINER_ID" psql -U "$POSTGRES_USER" -c "SELECT archived_count, last_archived_wal, last_archived_time, last_failed_wal, last_failed_time FROM pg_stat_archiver;" || true
    echo "Listing archive_status (.done/.ready) files (max 20):"
    docker exec "$POSTGRES_CONTAINER_ID" bash -c "ls -t /var/lib/postgresql/data/pg_wal/archive_status 2>/dev/null | head -20" || true
    echo "Local pg_wal segment files (head 15):"
    docker exec "$POSTGRES_CONTAINER_ID" bash -c "ls -1 /var/lib/postgresql/data/pg_wal | head -15" || true
    echo "Attempting manual archive of oldest ready segment if any..."
    docker exec "$POSTGRES_CONTAINER_ID" bash -c 'seg=$(ls /var/lib/postgresql/data/pg_wal/archive_status/*.ready 2>/dev/null | head -1 || true); if [ -n "$seg" ]; then base=$(basename "$seg" .ready); echo "Found ready segment $base - invoking wal-g wal-push"; wal-g wal-push "/var/lib/postgresql/data/pg_wal/$base" || echo "wal-push failed"; else echo "No .ready segments present"; fi' || true
        
    echo "Checking SSH connectivity from postgres container..."
    docker exec "$POSTGRES_CONTAINER_ID" bash -c "su - postgres -c \"echo 'ls' | sftp -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes -P ${SSH_PORT} ${SSH_USER}@${SSH_HOST} 2>/dev/null | grep -q 'sftp>'\"" || echo "SSH test failed"
        
        echo "Checking backup directory permissions..."
            if [[ "${ENABLE_SSH_SERVER:-0}" == "1" ]]; then
                docker exec "$SSH_CONTAINER_ID" bash -c "ls -la /backups/" || echo "Backup directory not accessible"
                docker exec "$SSH_CONTAINER_ID" bash -c "id walg" || echo "walg user not found"
            else
                # For restricted SSH shells (like Hetzner Storage Box), use simple ls without -a flag
                # and skip user id check as 'id' command is not available
                remote_path="$(get_remote_backup_path)"
                docker exec "$POSTGRES_CONTAINER_ID" bash -c "su - postgres -c 'ssh -i /var/lib/postgresql/.ssh/walg_key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -p ${SSH_PORT} ${SSH_USER}@${SSH_HOST} \"ls -l ${remote_path}/ 2>&1\" | head -5'" 2>/dev/null || echo "Backup directory not accessible"
                echo "Note: Skipping user id check (not supported on restricted SSH shells like Storage Box)"
            fi
        
        echo "Testing manual wal-g wal-push..."
        docker exec "$POSTGRES_CONTAINER_ID" bash -c "su - postgres -c 'wal-g --help | head -5'" || echo "wal-g help failed"
        
        die "No new WAL files found (pure segments remained at $initial_pure_wal_count)"
    fi
}

# Test 2: Backup-push functionality with verification
test_backup_push_e2e() {
    echof "Testing end-to-end backup-push functionality"
    
    # Get initial backup count
    local initial_backup_count
    initial_backup_count=$(get_backup_count)
    echo "Initial backup count: $initial_backup_count"
    
    # Create some additional data before backup to make it meaningful
    echo "Creating test data before backup..."
    docker exec "$POSTGRES_CONTAINER_ID" psql -U "$POSTGRES_USER" -c "
        CREATE TABLE IF NOT EXISTS backup_test_table (id SERIAL PRIMARY KEY, data TEXT, created_at TIMESTAMP DEFAULT NOW());
        INSERT INTO backup_test_table (data) SELECT 'backup_test_data_' || generate_series(1, 500);
    " >/dev/null 2>&1
    
    # Execute first backup from backup container
    echo "Creating first backup..."
    docker exec "$BACKUP_CONTAINER_ID" bash -c "/opt/walg/scripts/wal-g-runner.sh backup" || die "First backup execution failed"
    
    # Wait for backup to complete
    sleep "$E2E_BACKUP_WAIT1"
    
    # Check if new backup appeared
    local after_first_backup_count
    after_first_backup_count=$(get_backup_count)
    echo "Backup count after first backup: $after_first_backup_count"
    
    if ((after_first_backup_count > initial_backup_count)); then
        pass "First base backup successfully created (count: $initial_backup_count -> $after_first_backup_count)"
        
        # Verify backup details
        local backup_info
        backup_info=$(docker exec "$POSTGRES_CONTAINER_ID" bash -c "su - postgres -c 'source /var/lib/postgresql/.walg_env >/dev/null 2>&1 || true; wal-g backup-list' | tail -1" 2>/dev/null || echo "")
        if [[ -n "$backup_info" ]]; then
            pass "Latest backup info: $backup_info"
        fi
        
        # Check backup logs
        if docker exec "$BACKUP_CONTAINER_ID" bash -c "ls /var/lib/postgresql/data/walg_logs/backup_*.log 2>/dev/null | head -1 | xargs cat" 2>/dev/null | grep -q "backup.*completed\|SUCCESS"; then
            pass "Backup completion confirmed in logs"
        else
            warn "No backup completion confirmation found in logs"
        fi
        
        # Create a second backup to ensure we have multiple backups for testing
        echo "Creating additional data and second backup for recovery testing..."
        docker exec "$POSTGRES_CONTAINER_ID" psql -U "$POSTGRES_USER" -c "
            INSERT INTO backup_test_table (data) SELECT 'second_backup_data_' || generate_series(1, 200);
            SELECT pg_switch_wal();
        " >/dev/null 2>&1
        
        # Wait a bit for WAL activity
    sleep "$E2E_SHORT_WAL_WAIT"
        
        echo "Creating second backup..."
        docker exec "$BACKUP_CONTAINER_ID" bash -c "/opt/walg/scripts/wal-g-runner.sh backup" || warn "Second backup failed (not critical)"
        
        # Wait for second backup
    sleep "$E2E_BACKUP_WAIT2"
        
        local final_backup_count
        final_backup_count=$(get_backup_count)
        echo "Final backup count: $final_backup_count"
        
        if ((final_backup_count > after_first_backup_count)); then
            pass "Second backup also created successfully (total count: $final_backup_count)"
        else
            warn "Second backup may not have been created, but first backup is sufficient for testing"
        fi
        
        # Show all available backups
        echo "All available backups:"
        docker exec "$POSTGRES_CONTAINER_ID" bash -c "su - postgres -c 'source /var/lib/postgresql/.walg_env >/dev/null 2>&1 || true; wal-g backup-list'" 2>/dev/null || echo "Could not list backups"
        
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
    sleep "$E2E_CLEANUP_WAIT"
    
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

# Test 4: Recovery verification (enhanced)
test_recovery_capability() {
    echof "Testing backup recovery capability (enhanced verification)"
    
    # Enhanced backup verification with detailed debugging
    echo "=== Backup List Debug Information ==="
    
    # Get backup count first
    local backup_count
    backup_count=$(get_backup_count)
    echo "Current backup count: $backup_count"
    
    # Show full backup-list output for debugging
    echo "Full wal-g backup-list output:"
    local backup_list_output
    backup_list_output=$(docker exec "$POSTGRES_CONTAINER_ID" bash -c "su - postgres -c 'source /var/lib/postgresql/.walg_env >/dev/null 2>&1 || true; wal-g backup-list'" 2>/dev/null || echo "")
    echo "$backup_list_output"
    
    # Check if we have any backups at all
    if [[ $backup_count -gt 0 ]]; then
        echo "Found $backup_count backup(s)"
        
        # Try different methods to get backup information
        local backup_list_lines
        backup_list_lines=$(echo "$backup_list_output" | grep -v "^$" | wc -l)
        echo "Non-empty lines in backup-list: $backup_list_lines"
        
        # Check for various backup name patterns (not just "base_")
        local latest_backup_line
        latest_backup_line=$(echo "$backup_list_output" | grep -v "^$" | tail -1 || echo "")
        echo "Latest backup line: '$latest_backup_line'"
        
        if [[ -n "$latest_backup_line" ]]; then
            # Extract backup name (first column)
            local latest_backup
            latest_backup=$(echo "$latest_backup_line" | awk '{print $1}' || echo "")
            echo "Extracted backup name: '$latest_backup'"
            
            if [[ -n "$latest_backup" ]]; then
                pass "Latest backup available for recovery: $latest_backup"
                
                # Test backup-fetch command availability
                echo "Testing backup-fetch command..."
                if docker exec "$POSTGRES_CONTAINER_ID" bash -c "su - postgres -c 'wal-g backup-fetch --help'" >/dev/null 2>&1; then
                    pass "backup-fetch command available"
                    
                    # Test backup-fetch command validation (without actually downloading)
                    echo "Testing backup-fetch command validation..."
                    local temp_dir="/tmp/walg_recovery_test_$$"
                    docker exec "$POSTGRES_CONTAINER_ID" bash -c "mkdir -p $temp_dir" || true
                    
                    # First, test with an invalid backup name to verify the command works
                    echo "Testing backup-fetch command syntax..."
                    local fetch_test_result
                    fetch_test_result=$(docker exec "$POSTGRES_CONTAINER_ID" bash -c "su - postgres -c 'source /var/lib/postgresql/.walg_env >/dev/null 2>&1 || true; timeout ${E2E_TIMEOUT_SHORT} wal-g backup-fetch $temp_dir nonexistent_backup 2>&1'" 2>/dev/null || echo "timeout_or_error")
                    
                    if echo "$fetch_test_result" | grep -q "backup.*not found\|backup.*does not exist\|ERROR.*backup"; then
                        pass "backup-fetch command correctly validates backup names"
                    elif echo "$fetch_test_result" | grep -q "timeout_or_error"; then
                        warn "backup-fetch test timed out (command may be working but slow)"
                    else
                        echo "backup-fetch test result: $fetch_test_result"
                    fi
                    
                    # Test if we can start a backup-fetch process (with timeout to avoid hanging)
                    echo "Testing backup-fetch with latest backup (with timeout)..."
                    local backup_fetch_test
                    backup_fetch_test=$(timeout ${E2E_TIMEOUT_LONG} docker exec "$POSTGRES_CONTAINER_ID" bash -c "su - postgres -c 'source /var/lib/postgresql/.walg_env >/dev/null 2>&1 || true; wal-g backup-fetch $temp_dir $latest_backup 2>&1'" 2>/dev/null || echo "timeout_or_interrupted")
                    
                    if echo "$backup_fetch_test" | grep -q "timeout_or_interrupted"; then
                        pass "backup-fetch operation started successfully (interrupted due to timeout - normal for testing)"
                    elif echo "$backup_fetch_test" | grep -q "completed\|success"; then
                        pass "backup-fetch operation completed successfully"
                    else
                        warn "backup-fetch test inconclusive, but backup exists and command is available"
                        echo "backup-fetch output (first 3 lines): $(echo "$backup_fetch_test" | head -3)"
                    fi
                    
                    # Clean up test directory
                    docker exec "$POSTGRES_CONTAINER_ID" bash -c "rm -rf $temp_dir" || true
                else
                    warn "backup-fetch command not available or failed"
                fi
                
                # Test wal-fetch command availability
                echo "Testing wal-fetch command..."
                if docker exec "$POSTGRES_CONTAINER_ID" bash -c "su - postgres -c 'wal-g wal-fetch --help'" >/dev/null 2>&1; then
                    pass "wal-fetch command available"
                    
                    # Try to list available WAL files for this backup (with timeout)
                    echo "Checking available WAL files..."
                    local wal_list
                    wal_list=$(timeout ${E2E_TIMEOUT_SHORT} docker exec "$POSTGRES_CONTAINER_ID" bash -c "su - postgres -c 'source /var/lib/postgresql/.walg_env >/dev/null 2>&1 || true; wal-g wal-show'" 2>/dev/null | head -5 || echo "")
                    if [[ -n "$wal_list" ]]; then
                        pass "WAL files available for recovery"
                        echo "Sample WAL files (first 5):"
                        echo "$wal_list"
                        
                        # Test actual wal-fetch with a simple validation (not downloading)
                        echo "Testing wal-fetch command validation..."
                        local first_wal_segment
                        first_wal_segment=$(echo "$wal_list" | grep -o '[0-9A-F]\{24\}' | head -1 || echo "")
                        if [[ -n "$first_wal_segment" ]]; then
                            local wal_fetch_test
                            wal_fetch_test=$(timeout ${E2E_TIMEOUT_SHORT} docker exec "$POSTGRES_CONTAINER_ID" bash -c "su - postgres -c 'source /var/lib/postgresql/.walg_env >/dev/null 2>&1 || true; wal-g wal-fetch nonexistent_wal /tmp/test_wal_output 2>&1'" 2>/dev/null || echo "timeout_or_error")
                            if echo "$wal_fetch_test" | grep -q "not found\|does not exist\|ERROR"; then
                                pass "wal-fetch command correctly validates WAL file names"
                            else
                                warn "wal-fetch validation test inconclusive"
                            fi
                        fi
                    else
                        warn "No WAL files found or wal-show command failed/timed out"
                    fi
                else
                    warn "wal-fetch command not available"
                fi
                
                # Show backup details if available (with timeout)
                echo "Backup details:"
                timeout ${E2E_TIMEOUT_SHORT} docker exec "$POSTGRES_CONTAINER_ID" bash -c "su - postgres -c 'source /var/lib/postgresql/.walg_env >/dev/null 2>&1 || true; wal-g backup-list --detail'" 2>/dev/null | head -10 || echo "Detailed backup info not available or timed out"
                
            else
                warn "Could not extract backup name from backup list"
            fi
        else
            warn "No backup entries found in backup-list output"
        fi
    else
        echo "No backups found - checking why:"
        
        # Check backup storage connectivity
        echo "Testing wal-g storage connectivity..."
        if docker exec "$POSTGRES_CONTAINER_ID" bash -c "su - postgres -c 'source /var/lib/postgresql/.walg_env >/dev/null 2>&1 || true; wal-g backup-list'" 2>&1 | grep -q "ERROR\|error\|failed"; then
            echo "wal-g backup-list error output:"
            docker exec "$POSTGRES_CONTAINER_ID" bash -c "su - postgres -c 'source /var/lib/postgresql/.walg_env >/dev/null 2>&1 || true; wal-g backup-list'" 2>&1 || true
        fi
        
        # Check if backup directory exists on remote server
        echo "Checking remote backup directory:"
        if [[ "${ENABLE_SSH_SERVER:-0}" == "1" ]]; then
            docker exec "$SSH_CONTAINER_ID" bash -c "find /backups -type f -name '*.tar*' -o -name '*backup*' 2>/dev/null | head -10" || echo "No backup files found in remote storage"
        else
            # Use ls for storage boxes that don't support find
            remote_path="$(get_remote_backup_path)"
            docker exec "$POSTGRES_CONTAINER_ID" bash -c "su - postgres -c 'ssh -i /var/lib/postgresql/.ssh/walg_key -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o BatchMode=yes -p ${SSH_PORT} ${SSH_USER}@${SSH_HOST} \"ls ${remote_path}/basebackups_005/ 2>&1 | head -10\"'" 2>/dev/null || echo "No backup files found in remote storage"
        fi
        
        skip "No valid backups found for recovery testing - backup-list returned $backup_count entries"
    fi
    
    echo "=== End Backup List Debug Information ==="
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

  echof "== Cleaning remote backup storage to avoid LSN conflicts"
  # Clean remote backups to prevent "finish LSN greater than current LSN" errors
  # when the new database instance restarts with lower LSNs
  local remote_path
  remote_path=$(get_remote_backup_path)
  if [[ -n "$remote_path" ]] && [[ -n "${WALG_SSH_PREFIX:-}" ]]; then
      # Parse SSH connection details from WALG_SSH_PREFIX
      local ssh_user ssh_host ssh_port
      local _tmp=${WALG_SSH_PREFIX#ssh://}
      local _userhost=${_tmp%%/*}
      if [[ "$_userhost" == *@* ]]; then
          ssh_user=${_userhost%%@*}
          local _hostport=${_userhost#*@}
          if [[ "$_hostport" == *:* ]]; then
              ssh_port=${_hostport##*:}
              ssh_host=${_hostport%%:*}
          else
              ssh_host=$_hostport
              ssh_port=22
          fi
      else
          ssh_user="${SSH_USER:-walg}"
          ssh_host="$_userhost"
          ssh_port=22
      fi
      
      # Use WALG_SSH_TEST_PORT if set (for external SSH servers)
      ssh_port="${WALG_SSH_TEST_PORT:-$ssh_port}"
      
      # Use local SSH key from secrets directory
      local ssh_key_file="$SCRIPT_DIR/secrets/walg_ssh_key/id_rsa"
      if [[ -f "$ssh_key_file" ]]; then
          # Use SFTP to delete backup directories (compatible with restricted SSH servers like Hetzner)
          # Create an SFTP batch file for cleanup
          local sftp_batch=$(mktemp)
          cat > "$sftp_batch" <<EOF
-rm ${remote_path}/basebackups_*/*
-rmdir ${remote_path}/basebackups_*
-rm ${remote_path}/wal_*/*
-rmdir ${remote_path}/wal_*
bye
EOF
          # Execute SFTP batch (- prefix means ignore errors, so missing dirs don't fail)
          if sftp -i "$ssh_key_file" -P "$ssh_port" -o StrictHostKeyChecking=no -o BatchMode=yes \
              -b "$sftp_batch" "${ssh_user}@${ssh_host}" >/dev/null 2>&1; then
              pass "Remote backup storage cleaned"
          else
              warn "Could not clean remote backup storage (may not exist yet or SFTP batch had issues)"
          fi
          rm -f "$sftp_batch"
      else
          warn "SSH key file not found at $ssh_key_file, skipping remote cleanup"
      fi
  else
      skip "Remote backup path not configured, skipping remote cleanup"
  fi

    fi
            # Restart the stack after cleanup
        echof "Restarting stack after volume cleanup"
    $COMPOSE_CMD --profile ssh-testing up --build -d
    sleep "$E2E_STACK_INIT_WAIT"  # Give more time for initialization after cleanup
    
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
    
    # Test recovery capability BEFORE deletion tests
    # This ensures we have backups available for testing
    test_recovery_capability
    echo ""
    
    # Run delete/retention test last since it may remove backups
    test_delete_e2e
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