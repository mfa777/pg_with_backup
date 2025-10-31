#!/bin/bash
# Script to setup and start PgBouncer when ENABLE_PGBOUNCER=1

set -e

if [ "$ENABLE_PGBOUNCER" != "1" ]; then
    echo "PgBouncer is disabled (ENABLE_PGBOUNCER != 1)"
    exit 0
fi

echo "Setting up PgBouncer..."

# Use configurable ports with defaults
PGBOUNCER_PORT="${PGBOUNCER_PORT:-6432}"
PGBOUNCER_POOL_MODE="${PGBOUNCER_POOL_MODE:-session}"
PGBOUNCER_MAX_CLIENT_CONN="${PGBOUNCER_MAX_CLIENT_CONN:-100}"
PGBOUNCER_DEFAULT_POOL_SIZE="${PGBOUNCER_DEFAULT_POOL_SIZE:-20}"

# Create pgbouncer.ini from template
cp /etc/pgbouncer/pgbouncer.ini.template /etc/pgbouncer/pgbouncer.ini

# Update configuration with environment variables
sed -i "s/listen_port = .*/listen_port = ${PGBOUNCER_PORT}/" /etc/pgbouncer/pgbouncer.ini
sed -i "s/pool_mode = .*/pool_mode = ${PGBOUNCER_POOL_MODE}/" /etc/pgbouncer/pgbouncer.ini
sed -i "s/max_client_conn = .*/max_client_conn = ${PGBOUNCER_MAX_CLIENT_CONN}/" /etc/pgbouncer/pgbouncer.ini
sed -i "s/default_pool_size = .*/default_pool_size = ${PGBOUNCER_DEFAULT_POOL_SIZE}/" /etc/pgbouncer/pgbouncer.ini

# Create userlist.txt with PostgreSQL user credentials
# Format: "username" "md5_hash_of_password"
# The hash is md5(password + username)
if [ -n "$POSTGRES_USER" ] && [ -n "$POSTGRES_PASSWORD" ]; then
    # Calculate MD5 hash for PgBouncer auth using printf to avoid exposing password in process list
    # PgBouncer expects: "md5" + md5(password + username)
    HASH=$(printf '%s%s' "${POSTGRES_PASSWORD}" "${POSTGRES_USER}" | md5sum | cut -d' ' -f1)
    echo "\"${POSTGRES_USER}\" \"md5${HASH}\"" > /etc/pgbouncer/userlist.txt
    chown postgres:postgres /etc/pgbouncer/userlist.txt
    chmod 600 /etc/pgbouncer/userlist.txt
    echo "PgBouncer userlist created for user: ${POSTGRES_USER}"
else
    echo "Warning: POSTGRES_USER or POSTGRES_PASSWORD not set, PgBouncer authentication may fail"
fi

chown postgres:postgres /etc/pgbouncer/pgbouncer.ini
chmod 644 /etc/pgbouncer/pgbouncer.ini

echo "PgBouncer configuration created successfully"
echo "PgBouncer will listen on port: ${PGBOUNCER_PORT}"
echo "Pool mode: ${PGBOUNCER_POOL_MODE}"

# Start PgBouncer in the background as postgres user
# PgBouncer will be started after PostgreSQL is ready
