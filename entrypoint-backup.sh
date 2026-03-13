#!/bin/bash
set -e

# Enhanced entrypoint script that handles both SQL and WAL backup modes
WALG_ENV_PREPARE_SCRIPT="${WALG_ENV_PREPARE_SCRIPT:-/opt/walg/scripts/walg-env-prepare.sh}"

# Set timezone
if [ -n "$TZ" ]; then
    cp "/usr/share/zoneinfo/$TZ" /etc/localtime
    echo "$TZ" > /etc/timezone
    echo "Timezone set to $TZ"
fi

# Function to setup SQL mode cron
setup_sql_mode() {
    echo "Setting up SQL backup mode with schedule: ${BACKUP_CRON_SCHEDULE}"
    echo "${BACKUP_CRON_SCHEDULE} /usr/local/bin/backup.sh > /proc/1/fd/1 2>/proc/1/fd/2" | crontab -
}

# Function to setup WAL mode cron
setup_wal_mode() {
    local basebackup_cron="${WALG_BASEBACKUP_CRON:-30 1 * * *}"
    local clean_cron="${WALG_CLEAN_CRON:-15 3 * * *}"

    echo "Setting up WAL-G backup mode"
    
    # Prepare wal-g environment
    if [ ! -f "$WALG_ENV_PREPARE_SCRIPT" ]; then
        echo "ERROR: WAL-G env prepare script not found at $WALG_ENV_PREPARE_SCRIPT"
        exit 1
    fi
    # shellcheck disable=SC1090
    source "$WALG_ENV_PREPARE_SCRIPT"
    
    # Setup cron jobs for base backup and cleanup
    {
        echo "${basebackup_cron} /opt/walg/scripts/wal-g-runner.sh backup > /proc/1/fd/1 2>/proc/1/fd/2"
        echo "${clean_cron} /opt/walg/scripts/wal-g-runner.sh clean > /proc/1/fd/1 2>/proc/1/fd/2"
    } | crontab -
    
    echo "WAL-G cron jobs configured:"
    echo "  Base backup: ${basebackup_cron}"
    echo "  Cleanup: ${clean_cron}"
}

# Main logic based on BACKUP_MODE
if [ "$1" = 'crond' ]; then
    case "${BACKUP_MODE:-sql}" in
        sql)
            echo "Configuring SQL backup mode"
            setup_sql_mode
            ;;
        wal)
            echo "Configuring WAL-G backup mode"
            setup_wal_mode
            ;;
        *)
            echo "ERROR: Invalid BACKUP_MODE '${BACKUP_MODE}'. Must be 'sql' or 'wal'"
            exit 1
            ;;
    esac
    
    echo "Starting cron daemon..."
    crontab -l
fi

# Execute the CMD
exec "$@"
