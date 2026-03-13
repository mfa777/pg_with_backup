#!/bin/bash
# Shared notification helpers (Telegram)
# Source this file from backup scripts:
#   source /opt/scripts/notify.sh    (inside container)
#   source "$REPO_DIR/scripts/notify.sh"  (on host)

send_telegram_message() {
    local message="$1"
    if [[ -n "${TELEGRAM_BOT_TOKEN:-}" && -n "${TELEGRAM_CHAT_ID:-}" ]]; then
        local full_message="[${TELEGRAM_MESSAGE_PREFIX:-Backup}] $message"
        timeout 10s curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d chat_id="${TELEGRAM_CHAT_ID}" \
            -d text="${full_message}" \
            -d parse_mode="Markdown" >/dev/null 2>&1 || echo "Telegram notification failed."
    fi
}
