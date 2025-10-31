# Testing PgBouncer Integration

This document describes how to test the optional PgBouncer connection pooling feature.

## Automated Testing

The project includes an automated test suite for PgBouncer functionality. The tests are integrated into the main test runner and will automatically execute when `ENABLE_PGBOUNCER=1` is set.

### Running Automated Tests

```bash
# Set ENABLE_PGBOUNCER=1 in your .env file
echo "ENABLE_PGBOUNCER=1" >> .env

# Run the main test suite (includes PgBouncer tests)
./test/run-tests.sh

# Or run PgBouncer tests standalone
./test/test-pgbouncer.sh
```

The automated test suite validates:
- PgBouncer process is running in the PostgreSQL container
- PgBouncer is listening on the configured port (default 6432)
- Connections through PgBouncer work correctly
- Basic DDL operations (CREATE, INSERT, SELECT) work through PgBouncer
- PgBouncer admin console is accessible
- Connection pooling is functioning
- PgBouncer configuration is properly applied

## Manual Testing

### Prerequisites

- Docker installed and running
- The postgres-walg image built from `Dockerfile.postgres-walg`

## Test 1: Default Behavior (PgBouncer Disabled)

Test that the default behavior is unchanged when PgBouncer is disabled.

```bash
# Create test environment
cat > /tmp/test-default.env << 'EOF'
POSTGRES_USER=testuser
POSTGRES_PASSWORD=testpass
BACKUP_MODE=sql
ENABLE_PGBOUNCER=0
EOF

# Start container
docker run -d --name pg-test-default \
  --env-file /tmp/test-default.env \
  postgres-walg:latest

# Wait for PostgreSQL to be ready
docker exec pg-test-default pg_isready -U testuser

# Test PostgreSQL connection
docker exec pg-test-default psql -U testuser -c "SELECT version();" postgres

# Verify PgBouncer is NOT running
docker exec pg-test-default pgrep pgbouncer && echo "FAIL: PgBouncer should not be running" || echo "PASS: PgBouncer is disabled"

# Cleanup
docker rm -f pg-test-default
rm /tmp/test-default.env
```

## Test 2: PgBouncer Enabled

Test that PgBouncer starts correctly and accepts connections when enabled.

```bash
# Create test environment
cat > /tmp/test-pgbouncer.env << 'EOF'
POSTGRES_USER=testuser
POSTGRES_PASSWORD=testpass
BACKUP_MODE=sql
ENABLE_PGBOUNCER=1
PGBOUNCER_PORT=6432
EOF

# Start container
docker run -d --name pg-test-pgbouncer \
  --env-file /tmp/test-pgbouncer.env \
  -p 5433:5432 \
  -p 6433:6432 \
  postgres-walg:latest

# Wait for PostgreSQL to be ready
sleep 10
docker exec pg-test-pgbouncer pg_isready -U testuser

# Wait for PgBouncer to start
sleep 5

# Test direct PostgreSQL connection (port 5432)
echo "Testing direct PostgreSQL connection..."
docker exec pg-test-pgbouncer bash -c 'PGPASSWORD=testpass psql -h 127.0.0.1 -p 5432 -U testuser -c "SELECT 1;" postgres'

# Test PgBouncer connection (port 6432)
echo "Testing PgBouncer connection..."
docker exec pg-test-pgbouncer bash -c 'PGPASSWORD=testpass psql -h 127.0.0.1 -p 6432 -U testuser -c "SELECT current_database();" postgres'

# Verify PgBouncer process is running
docker exec pg-test-pgbouncer pgrep pgbouncer && echo "PASS: PgBouncer is running" || echo "FAIL: PgBouncer should be running"

# Check PgBouncer logs
echo "PgBouncer logs:"
docker exec pg-test-pgbouncer cat /var/log/pgbouncer/pgbouncer.log

# Cleanup
docker rm -f pg-test-pgbouncer
rm /tmp/test-pgbouncer.env
```

## Test 3: Connection Pool Configuration

Test that PgBouncer configuration variables work correctly.

```bash
# Create test environment with custom settings
cat > /tmp/test-custom.env << 'EOF'
POSTGRES_USER=testuser
POSTGRES_PASSWORD=testpass
ENABLE_PGBOUNCER=1
PGBOUNCER_PORT=7432
PGBOUNCER_POOL_MODE=transaction
PGBOUNCER_MAX_CLIENT_CONN=50
PGBOUNCER_DEFAULT_POOL_SIZE=10
EOF

# Start container
docker run -d --name pg-test-custom \
  --env-file /tmp/test-custom.env \
  postgres-walg:latest

# Wait for startup
sleep 15

# Verify custom configuration
echo "Checking custom PgBouncer configuration..."
docker exec pg-test-custom cat /etc/pgbouncer/pgbouncer.ini | grep "listen_port = 7432"
docker exec pg-test-custom cat /etc/pgbouncer/pgbouncer.ini | grep "pool_mode = transaction"
docker exec pg-test-custom cat /etc/pgbouncer/pgbouncer.ini | grep "max_client_conn = 50"

# Test connection on custom port
docker exec pg-test-custom bash -c 'PGPASSWORD=testpass psql -h 127.0.0.1 -p 7432 -U testuser -c "SELECT 1;" postgres'

# Cleanup
docker rm -f pg-test-custom
rm /tmp/test-custom.env
```

## Expected Results

- **Test 1**: PostgreSQL works normally, PgBouncer process is not present
- **Test 2**: Both direct PostgreSQL (5432) and PgBouncer (6432) connections work
- **Test 3**: PgBouncer uses custom configuration values

## Troubleshooting

If PgBouncer fails to start, check:

1. Container logs: `docker logs <container_name>`
2. PgBouncer logs: `docker exec <container_name> cat /var/log/pgbouncer/pgbouncer.log`
3. PgBouncer process: `docker exec <container_name> ps aux | grep pgbouncer`
4. Configuration: `docker exec <container_name> cat /etc/pgbouncer/pgbouncer.ini`
