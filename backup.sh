#!/bin/bash -l
set -eo pipefail # Exit on error, treat unset variables as errors, pipe failures

# --- Configuration (Should match environment variables) ---
PGUSER="${POSTGRES_USER:-postgres}"
PGHOST="${PGHOST:-postgres}" # Connect to the postgres container
PGPORT="${POSTGRES_PORT:-5432}"
BACKUP_DIR="/tmp/backups"
STATE_DIR="/var/lib/postgresql/data/backup_state" # Directory within the persistent volume
LAST_HASH_FILE="${STATE_DIR}/last_backup.hash"
KEEP_DAYS=${SQL_BACKUP_RETAIN_DAYS:-7} # How many days of backups to keep remotely, default to 7
TIMESTAMP=$(date +%Y%m%d_%H%M%S)

# --- Add timestamp to all subsequent output ---
# Redirect stdout and stderr through awk to prepend timestamp
exec > >(awk '{ print strftime("[%Y-%m-%d %H:%M:%S]"), $0; fflush(); }') 2>&1

# --- Ensure state directory exists ---
mkdir -p "$STATE_DIR"
# Optional: Ensure postgres user owns it if script runs as root initially
# chown postgres:postgres "$STATE_DIR"

# --- Telegram Notifications (Only for failures) ---
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID}"
TELEGRAM_MESSAGE_PREFIX="${TELEGRAM_MESSAGE_PREFIX}"

send_telegram_message() {
  if [[ -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]]; then
      local message="\\[${TELEGRAM_MESSAGE_PREFIX}\\] $1"
    # Use timeout to prevent script hanging
    timeout 10s curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -d chat_id="${TELEGRAM_CHAT_ID}" \
      -d text="${message}" \
      -d parse_mode="Markdown" || echo "Telegram notification failed."
  fi
}

# --- Cleanup function to ensure we don't leave temporary files ---
cleanup() {
  rm -f "$BACKUP_DIR/temp_dump.sql.gz" 2>/dev/null || true
  rm -f "$DUMP_FILE" 2>/dev/null || true
  rm -f "$ENC_FILE" 2>/dev/null || true
}

# Set trap to ensure cleanup on exit
trap cleanup EXIT

# --- Check required environment variables ---
required_vars=("AGE_PUBLIC_KEY" "REMOTE_PATH" "RCLONE_CONFIG_BASE64" "POSTGRES_PASSWORD")
for var in "${required_vars[@]}"; do
  if [[ -z "${!var}" ]]; then
    echo "Error: $var environment variable is not set."
    send_telegram_message "ERROR: $var is not set. Backup failed."
    exit 1
  fi
done

# --- Check for required commands ---
for cmd in pg_dumpall age rclone base64; do
    if ! command -v $cmd &> /dev/null; then
    echo "Error: Required command '$cmd' not found."
    send_telegram_message "ERROR: Required command '$cmd' not found. Backup failed."
    exit 1
  fi
done

# --- Ensure backup directory exists and is clean ---
mkdir -p "$BACKUP_DIR"
rm -rf "$BACKUP_DIR"/*

# --- Create temporary dump for comparison ---
TEMP_DUMP_FILE="$BACKUP_DIR/temp_dump.sql.gz"
export PGPASSWORD="${POSTGRES_PASSWORD}"
if ! pg_dumpall -U "$PGUSER" -h "$PGHOST" -p "$PGPORT" | gzip > "$TEMP_DUMP_FILE"; then
  echo "Error: Database dump failed."
  send_telegram_message "ERROR: Database dump failed. Backup aborted."
  unset PGPASSWORD
  exit 1
fi
unset PGPASSWORD

# --- Check if dump has changed ---
CURRENT_HASH=$(sha256sum "$TEMP_DUMP_FILE" | awk '{ print $1 }')
LAST_HASH=""
if [[ -f "$LAST_HASH_FILE" ]]; then
  LAST_HASH=$(cat "$LAST_HASH_FILE")
fi

if [[ "$CURRENT_HASH" == "$LAST_HASH" ]]; then
  echo "No changes detected since last backup. Skipping upload."
  exit 0
fi

# --- Proceed with actual backup ---
echo "Starting PostgreSQL backup process..."
DUMP_FILE="$BACKUP_DIR/all_databases_${TIMESTAMP}.sql.gz"
mv "$TEMP_DUMP_FILE" "$DUMP_FILE"
echo "Database dump complete."

# --- Encrypt dump ---
ENC_FILE="${DUMP_FILE}.age"
echo "Encrypting $DUMP_FILE to $ENC_FILE..."
if ! age -o "$ENC_FILE" -r "$AGE_PUBLIC_KEY" "$DUMP_FILE"; then
  echo "Error: Encryption command failed."
  send_telegram_message "ERROR: Encryption command failed. Backup aborted."
  exit 1
fi

# Check if encryption was successful (output file exists and is non-empty)
if [[ ! -s "$ENC_FILE" ]]; then
  echo "Error: Encryption failed or produced an empty file."
  send_telegram_message "ERROR: Encryption failed. Backup aborted."
  exit 1
fi

rm -f "$DUMP_FILE" # Remove original dump after successful encryption
echo "Encryption complete."

# --- Configure rclone (using base64 env var) ---
RCLONE_CONFIG_DIR="/config/rclone"
mkdir -p "$RCLONE_CONFIG_DIR"
if ! echo "$RCLONE_CONFIG_BASE64" | base64 -d > "$RCLONE_CONFIG_DIR/rclone.conf"; then
  echo "Error: Failed to decode RCLONE_CONFIG_BASE64."
  send_telegram_message "ERROR: Failed to decode RCLONE_CONFIG_BASE64. Backup aborted."
  exit 1
fi
RCLONE_CONFIG_OPT="--config $RCLONE_CONFIG_DIR/rclone.conf"

# --- Upload to remote ---
echo "Uploading $ENC_FILE to $REMOTE_PATH..."
if ! rclone copy "$ENC_FILE" "$REMOTE_PATH/" $RCLONE_CONFIG_OPT --progress; then
  echo "Error: Rclone upload failed."
  send_telegram_message "ERROR: Rclone upload failed."
  exit 1
fi

rm -f "$ENC_FILE" # Remove encrypted file after successful upload
echo "Upload complete."

# --- Update last hash ---
echo "$CURRENT_HASH" > "$LAST_HASH_FILE"
echo "Updated last backup hash."

# --- Cleanup old backups ---
echo "Cleaning up remote backups older than $KEEP_DAYS days..."
if ! rclone delete "$REMOTE_PATH/" --min-age "${KEEP_DAYS}d" $RCLONE_CONFIG_OPT --progress; then
  echo "Warning: Remote cleanup failed, but backup was successful."
fi
echo "Remote cleanup complete."

echo "Backup process finished successfully."

exit 0
