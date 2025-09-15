#!/bin/bash
# Mock wal-g script for testing when network connectivity is limited
# This script simulates wal-g operations for testing purposes

set -euo pipefail

# Configuration
MOCK_BACKUP_DIR="${MOCK_BACKUP_DIR:-/tmp/mock-walg-backups}"
LOG_FILE="${MOCK_BACKUP_DIR}/walg.log"

# Create backup directory if it doesn't exist
mkdir -p "$MOCK_BACKUP_DIR"

# Logging function
log() {
    echo "[$(date -Iseconds)] $*" | tee -a "$LOG_FILE"
}

# Help function
show_help() {
    cat << EOF
Mock wal-g for testing - simulates real wal-g behavior

Commands:
  backup-list       List all backups
  backup-push       Create a new backup
  wal-push          Archive a WAL file
  delete            Delete old backups
  --help            Show this help
  --version         Show version

Environment variables:
  WALG_SSH_PREFIX         SSH destination (for simulation)
  WALG_RETENTION_FULL     Number of full backups to retain
EOF
}

# Simulate backup-list
backup_list() {
    log "Executing backup-list"
    if [[ -f "$MOCK_BACKUP_DIR/backups.txt" ]]; then
        cat "$MOCK_BACKUP_DIR/backups.txt"
    else
        log "No backups found"
    fi
}

# Simulate backup-push
backup_push() {
    local pgdata="${1:-/var/lib/postgresql/data}"
    log "Executing backup-push for $pgdata"
    
    # Generate a mock backup entry
    local backup_name="base_$(date +%Y%m%dT%H%M%S)"
    local backup_size="$(du -sh $pgdata 2>/dev/null | cut -f1 || echo '100MB')"
    
    # Add to backup list
    echo "$backup_name    $(date -Iseconds)    $backup_size    FULL" >> "$MOCK_BACKUP_DIR/backups.txt"
    
    # Create a mock backup file
    touch "$MOCK_BACKUP_DIR/${backup_name}.tar.lz4"
    
    log "Backup $backup_name created successfully"
    echo "Backup $backup_name completed"
    return 0
}

# Simulate wal-push
wal_push() {
    local wal_file="$1"
    log "Executing wal-push for $wal_file"
    
    if [[ -f "$wal_file" ]]; then
        # Create compressed WAL file in mock storage
        local wal_basename=$(basename "$wal_file")
        touch "$MOCK_BACKUP_DIR/${wal_basename}.lz4"
        log "WAL file $wal_basename archived successfully"
        echo "WAL file archived: $wal_basename"
        return 0
    else
        log "ERROR: WAL file $wal_file not found"
        return 1
    fi
}

# Simulate delete with retention
delete_old_backups() {
    log "Executing delete with retention"
    
    local retention="${WALG_RETENTION_FULL:-7}"
    
    if [[ -f "$MOCK_BACKUP_DIR/backups.txt" ]]; then
        local backup_count=$(wc -l < "$MOCK_BACKUP_DIR/backups.txt")
        
        if ((backup_count > retention)); then
            local to_delete=$((backup_count - retention))
            log "Deleting $to_delete old backups (retention: $retention)"
            
            # Remove oldest backups
            head -n "$to_delete" "$MOCK_BACKUP_DIR/backups.txt" | while read backup_line; do
                local backup_name=$(echo "$backup_line" | awk '{print $1}')
                log "Deleting backup: $backup_name"
                rm -f "$MOCK_BACKUP_DIR/${backup_name}.tar.lz4"
            done
            
            # Update backup list
            tail -n "+$((to_delete + 1))" "$MOCK_BACKUP_DIR/backups.txt" > "$MOCK_BACKUP_DIR/backups.txt.tmp"
            mv "$MOCK_BACKUP_DIR/backups.txt.tmp" "$MOCK_BACKUP_DIR/backups.txt"
            
            echo "Deleted $to_delete old backups"
        else
            log "No backups to delete (current: $backup_count, retention: $retention)"
        fi
    else
        log "No backup list found"
    fi
}

# Main command processing
case "${1:-help}" in
    "backup-list")
        backup_list
        ;;
    "backup-push")
        backup_push "${2:-/var/lib/postgresql/data}"
        ;;
    "wal-push")
        if [[ -z "${2:-}" ]]; then
            echo "Error: wal-push requires WAL file path" >&2
            exit 1
        fi
        wal_push "$2"
        ;;
    "delete")
        case "${2:-}" in
            "retain"|"FULL")
                delete_old_backups
                ;;
            *)
                log "Delete command with parameters: $*"
                echo "Mock delete executed"
                ;;
        esac
        ;;
    "--help"|"help")
        show_help
        ;;
    "--version")
        echo "mock-wal-g v1.0.0 (testing version)"
        ;;
    *)
        echo "Unknown command: $1" >&2
        echo "Use --help for available commands" >&2
        exit 1
        ;;
esac