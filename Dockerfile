# Use an official PostgreSQL image (choose a specific version, e.g., 17)
# FROM postgres:17
# lobechat require pgvector
FROM pgvector/pgvector:pg17

# Install necessary tools: cron, curl, unzip (for rclone install), gnupg, ca-certificates, tzdata
# Also clean up apt cache afterwards
RUN apt-get update && apt-get install -y --no-install-recommends \
    cron \
    curl \
    unzip \
    gnupg \
    ca-certificates \
    tzdata \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# Install rclone using the official script
RUN curl https://rclone.org/install.sh | bash

# Install age (downloading from GitHub Releases)
# Note: Check for the latest age version URL if needed
ARG AGE_VERSION=v1.1.1
RUN curl -L "https://github.com/FiloSottile/age/releases/download/${AGE_VERSION}/age-${AGE_VERSION}-linux-amd64.tar.gz" | tar xz \
    && mv age/age /usr/local/bin/age \
    && mv age/age-keygen /usr/local/bin/age-keygen \
    && rm -rf age \
    && age --version

# Set the timezone (e.g., Asia/Shanghai for GMT+8)
# This value can be overridden by the TZ environment variable in docker-compose.yml
ENV TZ=Asia/Shanghai
RUN ln -snf /usr/share/zoneinfo/$TZ /etc/localtime && echo $TZ > /etc/timezone

# Create rclone configuration directory (config will be mounted here or passed via env var)
# Note: The actual rclone.conf is expected to be provided at runtime,
# either via volume mount to /config/rclone/rclone.conf or via RCLONE_CONFIG_BASE64 env var.
RUN mkdir -p /config/rclone

# Create directory for backup scripts and copy the script
COPY backup.sh /etc/scripts/backup.sh
RUN chown postgres:postgres /etc/scripts/backup.sh && \
    chmod 700 /etc/scripts/backup.sh

# Copy the cron job file
COPY pg_backup_cron /etc/cron.d/pg_backup_cron
# Give the cron job file the correct permissions
RUN chmod 0644 /etc/cron.d/pg_backup_cron
# Note: Cron logs are typically redirected to the container's stdout/stderr, viewable with 'docker logs'


# Modify the entrypoint: start cron first, then execute the default postgres entrypoint
# Create a new entrypoint script
COPY <<EOF /usr/local/bin/docker-entrypoint-cron.sh
#!/bin/bash
set -e

# Start the cron daemon in the foreground (output will be redirected)
# Using "-f" keeps it running; "&" puts it in the background immediately
cron -f &

# Execute the original postgres entrypoint script, passing all arguments
exec /usr/local/bin/docker-entrypoint.sh "\$@"
EOF

# Make the new entrypoint script executable
RUN chmod +x /usr/local/bin/docker-entrypoint-cron.sh

# Use the new entrypoint
ENTRYPOINT ["/usr/local/bin/docker-entrypoint-cron.sh"]
# Set the default command (passed to the entrypoint)
CMD ["postgres"]
