#!/bin/bash
set -eo pipefail

# wal-g runner script for base backups and cleanup
# Usage: wal-g-runner.sh [backup|clean|combo]

SCRIPT_NAME="wal-g-runner"
PGDATA="/var/lib/postgresql/data"
LOCK_DIR="$PGDATA/walg_locks"
LOG_DIR="$PGDATA/walg_logs"

# Create necessary directories
mkdir -p "$LOCK_DIR" "$LOG_DIR"

# Logging function with timestamp
log() {
    echo "[$(date -Iseconds)] $*"
}

# Telegram notification function (reuse from backup.sh pattern)
send_telegram_message() {
    local message="$1"
    if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
        curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d "chat_id=${TELEGRAM_CHAT_ID}" \
            -d "text=${TELEGRAM_MESSAGE_PREFIX:-WAL-G}: $message" >/dev/null 2>&1 || true
    fi
}

# Acquire lock function
acquire_lock() {
    local lock_file="$1"
    local lock_path="$LOCK_DIR/$lock_file"
    
    exec 9>"$lock_path"
    if ! flock -n 9; then
        log "Another $lock_file operation is running, skipping"
        return 3
    fi
    return 0
}

# Validate environment
validate_env() {
    log "Validating wal-g environment..."
    
    if [ -z "$WALG_SSH_PREFIX" ]; then
        log "ERROR: WALG_SSH_PREFIX is required"
        send_telegram_message "ERROR: WALG_SSH_PREFIX not configured"
        return 2
    fi
    
    if ! command -v wal-g &> /dev/null; then
        log "ERROR: wal-g binary not found"
        send_telegram_message "ERROR: wal-g binary not found"
        return 2
    fi
    
    log "Environment validation passed"
    return 0
}

# Run base backup
run_backup() {
    log "Starting wal-g base backup..."
    
    if ! acquire_lock "basebackup.lock"; then
        return $?
    fi
    
    local start_time=$(date +%s)
    local log_file="$LOG_DIR/backup_$(date +%Y%m%d_%H%M%S).log"
    
    # Force full backup if requested
    local backup_cmd="wal-g backup-push $PGDATA"
    if [ "$FORCE_FULL" = "1" ]; then
        log "Forcing full backup (FORCE_FULL=1)"
        unset WALG_DELTA_MAX_STEPS
    fi
    
    # Execute backup
    if $backup_cmd 2>&1 | tee "$log_file"; then
        local duration=$(($(date +%s) - start_time))
        
        # Determine backup type (FULL or DELTA)
        local backup_type="UNKNOWN"
        if grep -q "delta backup" "$log_file" 2>/dev/null; then
            backup_type="DELTA"
        elif grep -q "full backup\|backup completed" "$log_file" 2>/dev/null; then
            backup_type="FULL"
        fi
        
        log "Backup completed successfully (Type: $backup_type, Duration: ${duration}s)"
        
        # Update status file
        {
            echo "$(date -Iseconds) OK TYPE=$backup_type"
            echo "Duration=${duration}s"
            echo "LogFile=$log_file"
        } > "$PGDATA/walg_basebackup.last"
        
        # Create symlink to latest log
        ln -sf "$log_file" "$LOG_DIR/latest.log"
        
        return 0
    else
        log "ERROR: Backup failed"
        send_telegram_message "ERROR: Base backup failed. Check logs."
        return 1
    fi
}

# Run cleanup/retention
run_cleanup() {
    log "Starting wal-g cleanup..."
    
    if ! acquire_lock "cleanup.lock"; then
        return $?
    fi
    
    local retain_full=${WALG_RETENTION_FULL:-7}
    local log_file="$LOG_DIR/cleanup_$(date +%Y%m%d_%H%M%S).log"
    
    log "Retaining $retain_full full backups"
    
    # Execute cleanup
    if wal-g delete retain FULL "$retain_full" --confirm 2>&1 | tee "$log_file"; then
        log "Cleanup completed successfully"
        
        # Update cleanup status
        echo "$(date -Iseconds) CLEANUP_OK RETAIN_FULL=$retain_full" > "$PGDATA/walg_cleanup.last"
        
        return 0
    else
        log "ERROR: Cleanup failed"
        send_telegram_message "ERROR: WAL-G cleanup failed. Check logs."
        return 1
    fi
}

# Main execution
main() {
    local mode="${1:-backup}"
    
    log "wal-g-runner starting (mode: $mode)"
    
    # Validate environment first
    if ! validate_env; then
        exit 2
    fi
    
    case "$mode" in
        backup)
            run_backup
            ;;
        clean)
            run_cleanup
            ;;
        combo)
            if run_backup; then
                log "Backup successful, proceeding with cleanup"
                run_cleanup
            else
                log "Backup failed, skipping cleanup"
                exit 1
            fi
            ;;
        *)
            log "ERROR: Unknown mode '$mode'. Use: backup, clean, or combo"
            exit 2
            ;;
    esac
}

# Execute main function with all arguments
main "$@"