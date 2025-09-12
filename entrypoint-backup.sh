#!/bin/bash
set -e

# Enhanced entrypoint script that handles both SQL and WAL backup modes

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
    echo "Setting up WAL-G backup mode"
    
    # Prepare wal-g environment
    source /opt/walg/scripts/walg-env-prepare.sh
    
    # Setup cron jobs for base backup and cleanup
    {
        echo "${WALG_BASEBACKUP_CRON:-'30 1 * * *'} /opt/walg/scripts/wal-g-runner.sh backup > /proc/1/fd/1 2>/proc/1/fd/2"
        echo "${WALG_CLEAN_CRON:-'15 3 * * *'} /opt/walg/scripts/wal-g-runner.sh clean > /proc/1/fd/1 2>/proc/1/fd/2"
    } | crontab -
    
    echo "WAL-G cron jobs configured:"
    echo "  Base backup: ${WALG_BASEBACKUP_CRON:-'30 1 * * *'}"
    echo "  Cleanup: ${WALG_CLEAN_CRON:-'15 3 * * *'}"
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