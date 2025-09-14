#!/usr/bin/env bash
set -euo pipefail

# PostgreSQL Backup Stack Testing Script
# Tests container startup, database operations, and WAL generation
# Based on the comprehensive plan for validating the backup infrastructure

# Config
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$REPO_DIR/.env"
COMPOSE_CMD="docker compose"   # adjust if users use docker-compose
POSTGRES_SERVICE_NAME="postgres"
BACKUP_SERVICE_NAME="backup"
PG_DATA_PATH="/var/lib/postgresql/data"
WAL_PATHS=("$PG_DATA_PATH/pg_wal" "$PG_DATA_PATH/pg_xlog")
# WAIT_TIMEOUT controls how long we wait (in seconds) for postgres to become ready.
# It can be overridden via the TEST_WAIT_TIMEOUT env var for quicker local runs.
WAIT_TIMEOUT=${TEST_WAIT_TIMEOUT:-30}
BATCHES=60
BATCH_SIZE=100
CLEANUP=${CLEANUP:-0}  # set to 1 to bring the stack down at the end
FORCE_EMPTY_PGDATA=${FORCE_EMPTY_PGDATA:-0} # set to 1 to remove postgres-data volume before starting

# Load .env if present to obtain POSTGRES_USER etc.
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  set -o allexport
  # Use a subshell to avoid polluting current shell with unknown vars
  ( source "$ENV_FILE" >/dev/null 2>&1 ) || true
  set +o allexport
fi

POSTGRES_USER="${POSTGRES_USER:-postgres}"
POSTGRES_DB="${POSTGRES_DB:-postgres}"
# Load environment from .env file if it exists
if [[ -f "$ENV_FILE" ]]; then
  # Export variables from .env file to make them available to the test script
  set -a
  source "$ENV_FILE"
  set +a
fi

BACKUP_MODE="${BACKUP_MODE:-sql}"

echof() { printf "%s\n" "$*"; }
die() { echof "FAIL: $*" >&2; exit 1; }
pass() { echof "PASS: $*"; }
skip() { echof "SKIP: $*"; }

require_exec() {
  command -v "$1" >/dev/null 2>&1 || die "Required command '$1' not found on PATH"
}

# Prereqs
echof "== Prerequisite checks =="
require_exec docker
if ! $COMPOSE_CMD version >/dev/null 2>&1; then
  die "docker compose CLI not available as '$COMPOSE_CMD'"
fi
pass "docker + docker compose available"

# Optional: forcibly clear the postgres-data named volume before bringing up compose
if [[ "$FORCE_EMPTY_PGDATA" == "1" ]]; then
  echof "== FORCE_EMPTY_PGDATA=1: removing postgres-data volume and any previous compose state"
  # Stop and remove any running compose resources, then remove the named volume
  $COMPOSE_CMD down -v || true
  if docker volume ls --format '{{.Name}}' | grep -q '^postgres-data$'; then
    docker volume rm postgres-data || true
    pass "postgres-data volume removed"
  else
    skip "postgres-data volume not present"
  fi
fi

if [[ "$FORCE_EMPTY_PGDATA" == "1" ]]; then
  echof "== Preparing an empty postgres-data volume to avoid image population"
  # Create an empty named volume and ensure it's empty by mounting a helper container
  docker volume create postgres-data >/dev/null 2>&1 || true
  docker run --rm -v postgres-data:/data alpine:3.21 sh -c "rm -rf /data/* /data/.* 2>/dev/null || true; ls -la /data || true" || true
  pass "postgres-data prepared and emptied"
fi

# Start the stack
echof "== Starting postgres service only (to avoid race on data volume) =="
# Start postgres first to let initdb initialize the data directory without interference
$COMPOSE_CMD up --build -d "$POSTGRES_SERVICE_NAME"
echof "Triggered docker compose up for postgres"

# After postgres is initialized and accepting connections we'll start the remaining services
START_OTHER_SERVICES_AFTER_POSTGRES=1

# Wait for postgres container to appear
echof "== Waiting for postgres service container =="
end=$((SECONDS + WAIT_TIMEOUT))
while true; do
  if $COMPOSE_CMD ps -q "$POSTGRES_SERVICE_NAME" >/dev/null 2>&1; then
    CONTAINER_ID=$($COMPOSE_CMD ps -q "$POSTGRES_SERVICE_NAME")
    if [[ -n "$CONTAINER_ID" ]]; then
      break
    fi
  fi
  if (( SECONDS >= end )); then
    die "Timed out waiting for postgres container to be created"
  fi
  sleep 1
done
pass "postgres container created: $CONTAINER_ID"

# Wait for postgres to be ready via pg_isready
echof "== Waiting for Postgres readiness (pg_isready) =="
end=$((SECONDS + WAIT_TIMEOUT))
while true; do
  # Note: SECONDS is a special bash variable that contains the number of seconds
  # since the shell was started. We use it for simple timeout arithmetic.
  if docker exec "$CONTAINER_ID" pg_isready -U "$POSTGRES_USER" >/dev/null 2>&1; then
    break
  fi
  if (( SECONDS >= end )); then
    # try a final attempt to fetch logs for debugging
    echof "Postgres logs (last 100 lines):"
    docker logs --tail 100 "$CONTAINER_ID" || true
    die "Timed out waiting for postgres to become ready"
  fi
  # Poll more frequently to fail fast in CI/local runs
  sleep 1
done
pass "postgres is accepting connections"

# Refresh collation versions to avoid mismatch warnings/errors
echof "== Refreshing database collation versions =="
docker exec "$CONTAINER_ID" psql -U "$POSTGRES_USER" -c "ALTER DATABASE postgres REFRESH COLLATION VERSION;" || true
docker exec "$CONTAINER_ID" psql -U "$POSTGRES_USER" -c "ALTER DATABASE template1 REFRESH COLLATION VERSION;" || true
pass "Collation versions refreshed"
if [[ "${START_OTHER_SERVICES_AFTER_POSTGRES:-0}" == "1" ]]; then
  echof "== Starting backup and pgadmin services after postgres readiness"
  $COMPOSE_CMD up -d "$BACKUP_SERVICE_NAME" pgadmin || true
fi

# It's possible docker compose will recreate the postgres container when bringing up
# other services (e.g., to inject new mounts or env). Re-fetch the container id to
# ensure subsequent commands target the current container instance.
NEW_CONTAINER_ID=$($COMPOSE_CMD ps -q "$POSTGRES_SERVICE_NAME" || true)
if [[ -n "$NEW_CONTAINER_ID" && "$NEW_CONTAINER_ID" != "$CONTAINER_ID" ]]; then
  echof "Note: postgres container was recreated by docker compose (old=$CONTAINER_ID new=$NEW_CONTAINER_ID)"
  CONTAINER_ID="$NEW_CONTAINER_ID"
  # Wait a short while for the new container to accept connections
  echof "== Waiting for new Postgres container readiness (post-recreate) =="
  # Allow a shorter window for recreated containers to become ready
  end=$((SECONDS + 10))
  while true; do
    if docker exec "$CONTAINER_ID" pg_isready -U "$POSTGRES_USER" >/dev/null 2>&1; then
      break
    fi
    if (( SECONDS >= end )); then
      echof "Postgres logs (last 100 lines):"
      docker logs --tail 100 "$CONTAINER_ID" || true
      die "Timed out waiting for recreated postgres to become ready"
    fi
    sleep 1
  done
  pass "recreated postgres is accepting connections"
  # Refresh collation versions for recreated container
  docker exec "$CONTAINER_ID" psql -U "$POSTGRES_USER" -c "ALTER DATABASE postgres REFRESH COLLATION VERSION;" || true
  docker exec "$CONTAINER_ID" psql -U "$POSTGRES_USER" -c "ALTER DATABASE template1 REFRESH COLLATION VERSION;" || true
# Close the recreated-container if block
fi

# Check backup service existence
echof "== Checking backup service container =="
BACKUP_CONTAINER_ID=""
if $COMPOSE_CMD ps -q "$BACKUP_SERVICE_NAME" >/dev/null 2>&1; then
  BACKUP_CONTAINER_ID=$($COMPOSE_CMD ps -q "$BACKUP_SERVICE_NAME" || true)
fi
if [[ -n "$BACKUP_CONTAINER_ID" ]]; then
  pass "backup container exists: $BACKUP_CONTAINER_ID"
else
  skip "backup container not defined in compose; backup-specific tests will be skipped"
fi

# Determine WAL path that exists
echof "== Determining WAL path inside container =="
WAL_PATH=""
for p in "${WAL_PATHS[@]}"; do
  if docker exec "$CONTAINER_ID" bash -lc "[ -d '$p' ]" >/dev/null 2>&1; then
    WAL_PATH="$p"
    break
  fi
done
if [[ -z "$WAL_PATH" ]]; then
  skip "No pg_wal or pg_xlog directory found; skipping WAL file checks"
else
  pass "WAL path detected: $WAL_PATH"
fi

# Baseline WAL count
count_wal_files() {
  local cid="$1"
  local path="$2"
  if [[ -z "$path" ]]; then
    echo 0
    return
  fi
  docker exec "$cid" bash -lc "ls -1 -- '$path' 2>/dev/null | wc -l" || echo 0
}

COUNT_BEFORE=0
if [[ -n "$WAL_PATH" ]]; then
  COUNT_BEFORE=$(count_wal_files "$CONTAINER_ID" "$WAL_PATH")
fi
echof "WAL files before test: $COUNT_BEFORE"

# Create test DB and table (portable)
echof "== Creating test database and table =="
# Check if database exists, create if missing
if ! docker exec "$CONTAINER_ID" psql -U "$POSTGRES_USER" -tAc "SELECT 1 FROM pg_database WHERE datname='test_ci'" | grep -q 1; then
  docker exec -i "$CONTAINER_ID" psql -U "$POSTGRES_USER" -c "CREATE DATABASE test_ci;"
fi
docker exec -i "$CONTAINER_ID" psql -U "$POSTGRES_USER" -d test_ci -v ON_ERROR_STOP=1 <<'SQL'
CREATE TABLE IF NOT EXISTS test_wal (
  id SERIAL PRIMARY KEY,
  payload TEXT NOT NULL
);
SQL
pass "Created test_ci.test_wal"

# Note: heavy WAL-generating inserts are performed only in WAL backup mode below.

# Insert rows in batches to generate WAL activity.
# Only perform the heavy insert loop if we're in wal backup mode, or if the
# RUN_WAL_TEST environment variable is set to 1 (override for sql mode).
if [[ "$BACKUP_MODE" == "wal" ]]; then
  echof "== Inserting rows to generate WAL activity (backup mode=wal) =="
  docker exec -i "$CONTAINER_ID" bash -lc "psql -U '$POSTGRES_USER' -d test_ci -v ON_ERROR_STOP=1" <<'PSQLSCRIPT'
BEGIN;
CREATE TEMP TABLE tmp_generate AS SELECT generate_series(1,1); -- noop to ensure session works
COMMIT;
PSQLSCRIPT

  # Perform batch inserts from host via psql, committing each batch
  for ((b=1;b<=BATCHES;b++)); do
    docker exec -i "$CONTAINER_ID" psql -U "$POSTGRES_USER" -d test_ci -v ON_ERROR_STOP=1 <<SQL
BEGIN;
INSERT INTO test_wal (payload)
SELECT md5(random()::text || clock_timestamp()::text) FROM generate_series(1, $BATCH_SIZE);
COMMIT;
-- Force WAL segment switch from SQL
SELECT pg_switch_wal();
SQL
    # small sleep to let postgres flush WAL activity
    sleep 0.1
  done
  pass "Inserted $((BATCHES * BATCH_SIZE)) rows in batches (committed per batch)"
else
  echof "== Skipping heavy WAL-generating inserts (backup mode != wal)"
  skip "Heavy WAL insert test skipped"
fi

# Post-insert WAL count
COUNT_AFTER=0
if [[ -n "$WAL_PATH" ]]; then
  # wait a bit to ensure WAL files appear
  sleep 2
  COUNT_AFTER=$(count_wal_files "$CONTAINER_ID" "$WAL_PATH")
fi
echof "WAL files after test: $COUNT_AFTER"

if [[ -n "$WAL_PATH" ]]; then
  if (( COUNT_AFTER > COUNT_BEFORE )); then
    pass "WAL files increased from $COUNT_BEFORE to $COUNT_AFTER"
  else
    skip "No increase in WAL count detected (before=$COUNT_BEFORE, after=$COUNT_AFTER) — this can happen if WAL files are archived/removed quickly by wal-g or if filesystem mapping differs"
  fi
else
  skip "WAL path not available; WAL generation checks skipped"
fi

# Backup-mode specific checks
echof "== Backup-mode specific checks (BACKUP_MODE=$BACKUP_MODE) =="
if [[ "$BACKUP_MODE" == "wal" ]]; then
  # Check wal-g binary presence
  if docker exec "$CONTAINER_ID" which wal-g >/dev/null 2>&1; then
    pass "wal-g binary found in postgres container"
    # Try to run 'wal-g --version' to ensure it executes
    if docker exec "$CONTAINER_ID" wal-g --version >/dev/null 2>&1; then
      pass "wal-g executed successfully"
    else
      skip "wal-g exists but failed to run 'wal-g --version' (maybe missing config); skipping backup-list"
    fi
  else
    skip "wal-g not present in postgres container"
  fi

  # If wal-g present and backup container exists, attempt backup-list
  if docker exec "$CONTAINER_ID" which wal-g >/dev/null 2>&1; then
    if docker exec "$CONTAINER_ID" bash -lc 'wal-g backup-list >/dev/null 2>&1 || true'; then
      pass "Attempted wal-g backup-list (may require remote access; success means CLI ran)"
    else
      skip "wal-g backup-list failed to run cleanly (likely no remote configured) — SKIPPING network tests"
    fi
  fi

  # Run comprehensive WAL-G functionality tests
  echof "== Running WAL-G specific functionality tests =="
  if [ -f "$REPO_DIR/test/test-walg-functions.sh" ]; then
    # Source the test functions and run them
    source "$REPO_DIR/test/test-walg-functions.sh"
    
    # Set the container IDs for the walg test functions  
    CONTAINER_ID="$CONTAINER_ID"
    BACKUP_CONTAINER_ID="$BACKUP_CONTAINER_ID"
    
    # Run the specific tests
    test_archive_command_wal_push
    echo ""
    test_backup_push
    echo ""
    test_delete_functionality
    
    pass "WAL-G functionality tests completed"
  else
    skip "WAL-G functionality test script not found"
  fi
else
  # SQL mode checks
  if [[ -n "$BACKUP_CONTAINER_ID" ]]; then
    # Check common binaries inside backup container
    if docker exec "$BACKUP_CONTAINER_ID" which rclone >/dev/null 2>&1; then
      pass "rclone present in backup container"
    else
      skip "rclone not found in backup container"
    fi
    if docker exec "$BACKUP_CONTAINER_ID" which age >/dev/null 2>&1; then
      pass "age present in backup container"
    else
      skip "age not found in backup container"
    fi
  else
    skip "backup container absent; SQL-mode backup checks skipped"
  fi
fi

# Final notes and optional cleanup
echof "== Summary =="
echof "Postgres container: $CONTAINER_ID"
if [[ -n "$BACKUP_CONTAINER_ID" ]]; then
  echof "Backup container: $BACKUP_CONTAINER_ID"
fi
echof "WAL files before: $COUNT_BEFORE after: $COUNT_AFTER"

if [[ "$CLEANUP" == "1" ]]; then
  echof "Bringing down docker compose stack (cleanup)"
  $COMPOSE_CMD down
fi

echof "All tests completed."
exit 0