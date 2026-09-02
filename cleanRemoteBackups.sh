#!/usr/bin/env bash
# Cloud Backup Cleanup (Google Drive) via rclone
# Usage: ./cleanRemoteBackups.sh [-v] [-d] [-f]

set -euo pipefail

# ─────────────────────────────────────────────
# Arguments
# ─────────────────────────────────────────────

VERBOSE=0
DRY_RUN=0
FORCE=0
while getopts ":vdf" opt; do
    case $opt in
        v) VERBOSE=1 ;;
        d) DRY_RUN=1 ;;
        f) FORCE=1 ;;
        *) echo "Usage: $0 [-v] [-d] [-f]"; exit 1 ;;
    esac
done

# ─────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
ENV_FILE="$SCRIPT_DIR/backup.env"

if [ ! -f "$ENV_FILE" ]; then
    echo "[ERROR] Configuration file $ENV_FILE not found." >&2
    exit 1
fi

source "$ENV_FILE"

# Required variables validation
: "${RCLONE_REMOTE:?Error: RCLONE_REMOTE not defined in backup.env}"
: "${REMOTE_RETENTION_DAYS:?Error: REMOTE_RETENTION_DAYS not defined in backup.env}"
REMOTE_CLEANUP_SAFETY_DAYS="${REMOTE_CLEANUP_SAFETY_DAYS:-2}"
DRIVE_DESTINATION="${DRIVE_DESTINATION:-Backups}"

# Log file defaults to the script directory
LOG_FILE="${LOG_FILE:-$SCRIPT_DIR/sync.log}"

# ─────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────

_log() {
    local level="$1"; shift
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
    echo "$msg"
    echo "$msg" >> "$LOG_FILE"
}

log_info()    { _log "INFO   " "$*"; }
log_warn()    { _log "WARN   " "$*" >&2; }
log_error()   { _log "ERROR  " "$*" >&2; }
log_verbose() {
    if [ "$VERBOSE" = "1" ]; then
        _log "VERBOSE" "$*"
    fi
}

# E-mail notifications (optional, configured in backup.env).
# Sourced after the log_* helpers because notify.sh relies on them.
if [ -f "$SCRIPT_DIR/notify.sh" ]; then
    # shellcheck source=/dev/null
    source "$SCRIPT_DIR/notify.sh"
else
    log_warn "notify.sh not found. E-mail notifications disabled."
    send_error_email() { :; }
    notify_host()     { echo "${HOSTNAME:-$(uname -n)}"; }
    notify_body()     { echo "$1"; }
    notify_log_tail() { :; }
fi

# Trap for unexpected errors
cleanup_on_error() {
    local exit_code=$?
    if [ $exit_code -ne 0 ]; then
        log_error "Script terminated unexpectedly with exit code $exit_code"
        send_error_email "$(notify_host): remote cleanup FAILED (exit $exit_code)" \
            "$(notify_body "The remote cleanup script terminated unexpectedly with exit code $exit_code.

Last log lines:
$(notify_log_tail 30)")"
    fi
}
trap cleanup_on_error EXIT

# ─────────────────────────────────────────────
# Safety Check
# ─────────────────────────────────────────────

REMOTE_PATH="${RCLONE_REMOTE}/${DRIVE_DESTINATION}"

if [ "$FORCE" = "1" ]; then
    log_warn "--- FORCE MODE ENABLED: Bypassing safety lock ---"
else
    log_verbose "Checking for recent backups (last $REMOTE_CLEANUP_SAFETY_DAYS days)..."

    # Search for recent files on Drive
    RECENT_FILES=$(rclone lsf "$REMOTE_PATH" --max-age "${REMOTE_CLEANUP_SAFETY_DAYS}d" --recursive --files-only 2>/dev/null | head -n 1) || true

    if [ -z "$RECENT_FILES" ]; then
        log_error "⚠️ SAFETY: No recent backups found on Drive in the last $REMOTE_CLEANUP_SAFETY_DAYS days!"
        log_error "Cleanup was ABORTED to preserve existing history. Check if the backup script is running."
        send_error_email "$(notify_host): remote cleanup ABORTED (no recent backups)" \
            "$(notify_body "SAFETY ABORT: no backup newer than $REMOTE_CLEANUP_SAFETY_DAYS day(s) was found at $REMOTE_PATH.

The cleanup was aborted to preserve the existing history, but this most likely
means the upload script has stopped working — please check it.

Last log lines:
$(notify_log_tail 20)")"
        trap - EXIT
        exit 1
    fi
    log_verbose "   ✓ Recent backup detected. Proceeding..."
fi

# ─────────────────────────────────────────────
# Cleanup Execution
# ─────────────────────────────────────────────

log_info "Starting cloud cleanup: $REMOTE_PATH"
log_info "Criteria: Files older than $REMOTE_RETENTION_DAYS days."

RCLONE_FLAGS=("--min-age" "${REMOTE_RETENTION_DAYS}d")

if [ "$VERBOSE" = "1" ]; then
    RCLONE_FLAGS+=("--log-level" "INFO")
fi

if [ "$DRY_RUN" = "1" ]; then
    log_warn "--- DRY-RUN MODE ENABLED ---"
    RCLONE_FLAGS+=("--dry-run")
fi

# Execute deletion
if rclone delete "$REMOTE_PATH" "${RCLONE_FLAGS[@]}"; then
    [ "$DRY_RUN" = "1" ] && log_info "Simulation completed. No files were deleted." || log_info "Cleanup completed successfully."
else
    log_error "Error executing Drive cleanup."
    send_error_email "$(notify_host): remote cleanup FAILED" \
        "$(notify_body "rclone delete failed for: $REMOTE_PATH
Criteria: files older than $REMOTE_RETENTION_DAYS days.

Last log lines:
$(notify_log_tail 20)")"
    trap - EXIT
    exit 1
fi

trap - EXIT
exit 0
