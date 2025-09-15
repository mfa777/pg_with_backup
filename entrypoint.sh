#!/bin/bash
# DEPRECATED: Use `entrypoint-backup.sh` (multi-mode) instead. Retained for
# backward compatibility in Phase 1. See CLEANUP.md
set -e

# Set timezone
if [ -n "$TZ" ]; then
    cp "/usr/share/zoneinfo/$TZ" /etc/localtime
    echo "$TZ" > /etc/timezone
    echo "Timezone set to $TZ"
fi

# If the command is crond, update the crontab schedule if env var is set
if [ "$1" = 'crond' ]; then
    echo "Updating cron schedule to: ${BACKUP_CRON_SCHEDULE}"
    # Write the cron job, redirecting output to Docker logs
    echo "${BACKUP_CRON_SCHEDULE} /usr/local/bin/backup.sh > /proc/1/fd/1 2>/proc/1/fd/2" | crontab -
fi

# Execute the CMD
exec "$@"
