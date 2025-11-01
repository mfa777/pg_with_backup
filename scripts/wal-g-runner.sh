#!/bin/bash
set -eo pipefail

# wal-g runner script for base backups and cleanup
# Usage: wal-g-runner.sh [backup|clean|combo]

# Source wal-g environment
if [ -f "/var/lib/postgresql/.walg_env" ]; then
    source "/var/lib/postgresql/.walg_env"
else
    echo "ERROR: wal-g environment file not found at /var/lib/postgresql/.walg_env"
    exit 1
fi

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

# Cross-platform date calculation helper
# Usage: calculate_epoch_days_ago DAYS
calculate_epoch_days_ago() {
    local days=$1
    local epoch=""
    
    # Try GNU date first (Linux)
    epoch=$(date -d "$days days ago" +%s 2>/dev/null)
    
    # If that fails, try BSD date (macOS)
    if [ -z "$epoch" ] || [ "$epoch" = "" ]; then
        epoch=$(date -v-"${days}"d +%s 2>/dev/null)
    fi
    
    # Return the epoch or empty string if both failed
    echo "$epoch"
}

# Convert epoch to ISO 8601 date
# Usage: epoch_to_iso8601 EPOCH
epoch_to_iso8601() {
    local epoch=$1
    local iso_date=""
    
    # Try GNU date first (Linux)
    iso_date=$(date -u -d "@$epoch" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)
    
    # If that fails, try BSD date (macOS)
    if [ -z "$iso_date" ] || [ "$iso_date" = "" ]; then
        iso_date=$(date -u -r "$epoch" +"%Y-%m-%dT%H:%M:%SZ" 2>/dev/null)
    fi
    
    echo "$iso_date"
}

# Parse backup timestamp and convert to epoch
# Usage: backup_timestamp_to_epoch TIMESTAMP
# TIMESTAMP format: YYYYMMDDTHHMMSS (e.g., 20240920T073000)
backup_timestamp_to_epoch() {
    local ts=$1
    local epoch=""
    
    # Validate input format
    if [[ ! "$ts" =~ ^[0-9]{8}T[0-9]{6}$ ]]; then
        echo "0"
        return 1
    fi
    
    local date_part="${ts:0:8}"
    local time_part="${ts:9:2}:${ts:11:2}:${ts:13:2}"
    
    # Try GNU date first (Linux)
    epoch=$(date -d "$date_part $time_part" +%s 2>/dev/null)
    
    # If that fails, try BSD date (macOS)
    if [ -z "$epoch" ] || [ "$epoch" = "" ]; then
        epoch=$(date -j -f "%Y%m%d %H:%M:%S" "$date_part $time_part" +%s 2>/dev/null)
    fi
    
    # Return epoch or 0 if conversion failed
    echo "${epoch:-0}"
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
    
    # Execute backup (capture output for retry logic)
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
        # Check if failure is due to delta/base mismatch (system identifier changed)
        if grep -qi "Current database and database of base backup are not equal" "$log_file"; then
            log "Detected system identifier mismatch during delta backup; retrying as full backup"
            # Force full backup by unsetting delta-related vars
            unset WALG_DELTA_MAX_STEPS
            local full_retry_log="${log_file%.log}_full_retry.log"
            if wal-g backup-push "$PGDATA" 2>&1 | tee "$full_retry_log"; then
                local duration=$(($(date +%s) - start_time))
                log "Full backup retry succeeded (Duration: ${duration}s)"
                ln -sf "$full_retry_log" "$LOG_DIR/latest.log"
                echo "$(date -Iseconds) OK TYPE=FULL_RETRY Duration=${duration}s LogFile=$full_retry_log" > "$PGDATA/walg_basebackup.last"
                return 0
            else
                log "ERROR: Full backup retry failed"
                send_telegram_message "ERROR: Full backup retry failed after delta mismatch."
            fi
        fi
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
    local retain_days=${WALG_RETENTION_DAYS:-}
    local log_file="$LOG_DIR/cleanup_$(date +%Y%m%d_%H%M%S).log"
    local cleanup_success=0
    
    # Execute time-based retention first if WALG_RETENTION_DAYS is set
    # This handles old backups that might not be caught by count-based retention
    if [ -n "$retain_days" ] && [ "$retain_days" -gt 0 ]; then
        log "Applying time-based retention: deleting backups older than $retain_days days"
        
        # Calculate cutoff timestamp (Unix epoch time for easier comparison)
        local cutoff_epoch
        cutoff_epoch=$(calculate_epoch_days_ago "$retain_days")
        
        if [ -z "$cutoff_epoch" ] || [ "$cutoff_epoch" = "0" ]; then
            log "ERROR: Failed to calculate cutoff date (platform date command may be incompatible)"
            send_telegram_message "ERROR: Time-based cleanup failed - date calculation error"
        else
            local cutoff_date
            cutoff_date=$(epoch_to_iso8601 "$cutoff_epoch")
            
            if [ -z "$cutoff_date" ]; then
                log "WARNING: Could not format cutoff date for display"
                cutoff_date="<unknown>"
            fi
            
            log "Cutoff date: $cutoff_date (epoch: $cutoff_epoch)"
            
            # Get backup list and find old backups to delete
            local backup_list
            backup_list=$(wal-g backup-list 2>/dev/null || true)
            
            if [ -n "$backup_list" ]; then
                # Parse backup list to find the first backup that should be kept (cutoff point)
                # All backups before this one will be deleted
                # Format: backup_name   modified_time   wal_segment_backup_start
                local first_backup_to_keep=""
                local found_old_backups=0
                
                while IFS= read -r line; do
                    # Skip header or empty lines
                    [[ "$line" =~ ^name ]] && continue
                    [[ -z "$line" ]] && continue
                    
                    # Extract backup name (first column)
                    local backup_name=$(echo "$line" | awk '{print $1}')
                    
                    # Extract timestamp from backup name (format: base_YYYYMMDDTHHMMSSZ)
                    if [[ "$backup_name" =~ base_([0-9]{8}T[0-9]{6}) ]]; then
                        local backup_ts="${BASH_REMATCH[1]}"
                        
                        # Convert to epoch for comparison
                        local backup_epoch
                        backup_epoch=$(backup_timestamp_to_epoch "$backup_ts")
                        
                        if [ "$backup_epoch" -gt 0 ]; then
                            if [ "$backup_epoch" -lt "$cutoff_epoch" ]; then
                                # This backup is old
                                found_old_backups=1
                                local age_days=$((($cutoff_epoch - $backup_epoch) / 86400))
                                log "Found old backup: $backup_name (age: $age_days days)"
                            elif [ $found_old_backups -eq 1 ] && [ -z "$first_backup_to_keep" ]; then
                                # This is the first backup after the cutoff - use it as the deletion boundary
                                first_backup_to_keep="$backup_name"
                                log "First backup to keep: $first_backup_to_keep"
                                break
                            fi
                        else
                            log "WARNING: Could not parse timestamp from backup: $backup_name"
                        fi
                    fi
                done <<< "$backup_list"
                
                # Delete old backups using the boundary backup
                if [ -n "$first_backup_to_keep" ]; then
                    log "Deleting all backups before: $first_backup_to_keep"
                    if wal-g delete before "$first_backup_to_keep" --confirm 2>&1 | tee -a "$log_file"; then
                        log "Successfully deleted old backups and associated WAL files"
                        cleanup_success=1
                    else
                        log "WARNING: Failed to delete old backups"
                    fi
                elif [ $found_old_backups -eq 1 ]; then
                    # All backups are old - keep at least one (the newest one)
                    log "WARNING: All backups are older than $retain_days days. Keeping the newest one for safety."
                else
                    log "INFO: No backups older than $retain_days days found"
                fi
            else
                log "INFO: No backups found for time-based cleanup"
            fi
        fi
    fi
    
    # Execute count-based retention (retain N full backups)
    # This ensures we always keep at least N backups regardless of age
    log "Retaining $retain_full full backups (count-based)"
    if wal-g delete retain FULL "$retain_full" --confirm 2>&1 | tee -a "$log_file"; then
        log "Count-based cleanup completed successfully"
        cleanup_success=1
    else
        log "INFO: Count-based cleanup found no backups to delete"
    fi
    
    # Report final status
    if [ $cleanup_success -eq 1 ]; then
        log "Cleanup completed successfully"
        
        # Update cleanup status
        local status_msg="CLEANUP_OK RETAIN_FULL=$retain_full"
        if [ -n "$retain_days" ]; then
            status_msg="$status_msg RETAIN_DAYS=$retain_days"
        fi
        echo "$(date -Iseconds) $status_msg" > "$PGDATA/walg_cleanup.last"
        
        return 0
    else
        log "INFO: Cleanup completed - no backups needed deletion"
        echo "$(date -Iseconds) CLEANUP_OK NO_DELETION_NEEDED" > "$PGDATA/walg_cleanup.last"
        return 0
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