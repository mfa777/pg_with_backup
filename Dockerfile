## DEPRECATED: This Dockerfile provided a SQL-mode only backup container.
## Replaced by `Dockerfile.backup` which supports both SQL and WAL modes.
## Will be removed in Phase 2. See CLEANUP.md
FROM alpine:3.21

# Set environment variables
ENV TZ=UTC
ENV BACKUP_CRON_SCHEDULE="0 2 * * *"

# Install required packages
RUN apk add --no-cache \
    bash \
    postgresql17-client \
    curl \
    rclone \
    age \
    tzdata \
    ca-certificates && \
    rm -rf /var/cache/apk/*

# Create directories
RUN mkdir -p /config/rclone /tmp/backups /var/lib/backup/state /var/log

# Copy backup script
COPY backup.sh /usr/local/bin/backup.sh
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /usr/local/bin/backup.sh /entrypoint.sh

# --- Setup Cron (will be finalized by entrypoint) ---
# Add a placeholder or default cron job definition
# The entrypoint script will overwrite this using the BACKUP_CRON_SCHEDULE env var
RUN echo "${BACKUP_CRON_SCHEDULE} /usr/local/bin/backup.sh > /proc/1/fd/1 2>/proc/1/fd/2" | crontab -

# --- Runtime ---
# Run the entrypoint script which sets timezone and starts crond
ENTRYPOINT ["/entrypoint.sh"]

# Start cron in the foreground
CMD ["crond", "-f", "-l", "8"]
