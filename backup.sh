#!/bin/bash
#!/bin/bash
set -eo pipefail # Exit on error, treat unset variables as errors, pipe failures

# --- Configuration (Should match environment variables) ---
PGUSER="${POSTGRES_USER:-postgres}"
PGHOST="localhost" # Connect via socket or localhost within the container
PGPORT="5432"
# RCLONE_CONFIG_BASE64 is read directly by rclone if set
AGE_PUBLIC_KEY="${AGE_PUBLIC_KEY}"
REMOTE_PATH="${REMOTE_PATH}"
BACKUP_DIR="/tmp/backups"
STATE_DIR="/var/lib/postgresql/data/backup_state" # Directory within the persistent volume
LAST_HASH_FILE="${STATE_DIR}/last_backup.hash"
KEEP_DAYS={SQL_BACKUP_RETAIN_DAYS} # How many days of backups to keep remotely

# --- Ensure state directory exists ---
mkdir -p "$STATE_DIR"
# Optional: Ensure postgres user owns it if script runs as root initially
# chown postgres:postgres "$STATE_DIR"

# --- Telegram Notifications (Optional) ---
TELEGRAM_BOT_TOKEN="${TELEGRAM_BOT_TOKEN}"
TELEGRAM_CHAT_ID="${TELEGRAM_CHAT_ID}"

send_telegram_message() {
  if [[ -n "$TELEGRAM_BOT_TOKEN" && -n "$TELEGRAM_CHAT_ID" ]]; then
    local message="[PostgresBackup] $1"
    # Use timeout to prevent script hanging
    timeout 10s curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
      -d chat_id="${TELEGRAM_CHAT_ID}" \
      -d text="${message}" \
      -d parse_mode="Markdown" || echo "Telegram notification failed."
  fi
}

echo "Starting PostgreSQL backup process..."
send_telegram_message "Starting backup process..."

# --- Ensure backup directory exists and is clean ---
mkdir -p "$BACKUP_DIR"
rm -rf "$BACKUP_DIR"/*

# --- Create dump ---
DUMP_FILE="$BACKUP_DIR/all_databases_$(date +%Y%m%d_%H%M%S).sql.gz"
echo "Dumping all databases to $DUMP_FILE..."
# Use pg_dumpall, run as postgres user if needed (depends on how cron runs it)
# Using PGPASSWORD if needed, or rely on .pgpass / service file / trust auth
export PGPASSWORD="${POSTGSTRS_PASSWORD}" # Make sure POSTGRES_PASSWORD is set in env
pg_dumpall -U "$PGUSER" -h "$PGHOST" -p "$PGPORT" | gzip > "$DUMP_FILE"
unset PGPASSWORD
echo "Database dump complete."

# --- Check if dump has changed ---
CURRENT_HASH=$(sha256sum "$DUMP_FILE" | awk '{ print $1 }')
LAST_HASH=""
if [[ -f "$LAST_HASH_FILE" ]]; then
  LAST_HASH=$(cat "$LAST_HASH_FILE")
fi

if [[ "$CURRENT_HASH" == "$LAST_HASH" ]]; then
  echo "No changes detected since last backup. Skipping upload."
  rm -f "$DUMP_FILE" # Clean up unchanged dump
  send_telegram_message "No database changes detected. Skipping upload."
  exit 0
else
   echo "Database changes detected. Proceeding with encryption and upload."
fi

# --- Encrypt dump ---
ENC_FILE="${DUMP_FILE}.age"
echo "Encrypting $DUMP_FILE to $ENC_FILE..."
if [[ -z "$AGE_PUBLIC_KEY" ]]; then
   echo "Error: AGE_PUBLIC_KEY environment variable is not set."
   send_telegram_message "ERROR: AGE_PUBLIC_KEY is not set. Backup failed."
   exit 1
fi
age -p -o "$ENC_FILE" -r "$AGE_PUBLIC_KEY" "$DUMP_FILE"
# Check if encryption was successful (output file exists and is non-empty)
if [[ ! -s "$ENC_FILE" ]]; then
    echo "Error: Encryption failed or produced an empty file."
    send_telegram_message "ERROR: Encryption failed. Backup aborted."
    rm -f "$DUMP_FILE" # Clean up original dump
    exit 1
fi
rm -f "$DUMP_FILE" # Remove original dump after successful encryption
echo "Encryption complete."

# --- Configure rclone (using base64 env var) ---
if [[ -n "$RCLONE_CONFIG_BASE64" ]]; then
    mkdir -p /config/rclone
    echo "$RCLONE_CONFIG_BASE64" | base64 -d > /config/rclone/rclone.conf
    RCLONE_CONFIG_OPT="--config /config/rclone/rclone.conf"
else
    echo "Warning: RCLONE_CONFIG_BASE64 not set. Relying on default rclone config path or other methods."
    RCLONE_CONFIG_OPT=""
fi

# --- Upload to remote ---
if [[ -z "$REMOTE_PATH" ]]; then
   echo "Error: REMOTE_PATH environment variable is not set."
   send_telegram_message "ERROR: REMOTE_PATH is not set. Backup failed."
   exit 1
fi
echo "Uploading $ENC_FILE to $REMOTE_PATH..."
rclone copy "$ENC_FILE" "$REMOTE_PATH/" $RCLONE_CONFIG_OPT --progress
# Check rclone exit code
if [[ $? -ne 0 ]]; then
    echo "Error: Rclone upload failed."
    send_telegram_message "ERROR: Rclone upload failed."
    # Keep the encrypted file locally for potential manual upload
    exit 1
fi
rm -f "$ENC_FILE" # Remove encrypted file after successful upload
echo "Upload complete."

# --- Update last hash ---
echo "$CURRENT_HASH" > "$LAST_HASH_FILE"
echo "Updated last backup hash."

# --- Cleanup old backups ---
echo "Cleaning up remote backups older than $KEEP_DAYS days..."
rclone delete "$REMOTE_PATH/" --min-age "${KEEP_DAYS}d" $RCLONE_CONFIG_OPT --progress
echo "Remote cleanup complete."

send_telegram_message "Backup successful and uploaded to $REMOTE_PATH."
echo "Backup process finished successfully."

exit 0
