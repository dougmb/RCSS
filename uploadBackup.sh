#!/usr/bin/env bash
# Backup Synchronization to Google Drive via rclone
# Usage: ./uploadBackup.sh [-v] [-p] [-s] [-D] [-k] [-n] [-o <origin>] [-r <rclone_remote>] [-d <drive_destination>] [-a <file>] [-i <ignored_folders>]
# This script iterates through /opt/backups/<PROJECT> and uploads to Drive.

set -euo pipefail

# ─────────────────────────────────────────────
# Arguments
# ─────────────────────────────────────────────

VERBOSE=0
SHOW_PROGRESS=0
BACKUP_ROOT_OVERRIDE=""
RCLONE_REMOTE_OVERRIDE=""
DRIVE_DESTINATION_OVERRIDE=""
SINGLE_FILE=""
IGNORED_FOLDERS_OVERRIDE=""
SKIP_DOTFILES_FLAG=0
DELETE_AFTER_UPLOAD_FLAG=0
KEEP_LOCAL_FLAG=0
DRY_RUN=0
while getopts ":vpsDkno:r:d:a:i:" opt; do
    case $opt in
        v) VERBOSE=1 ;;
        p) SHOW_PROGRESS=1 ;;
        s) SKIP_DOTFILES_FLAG=1 ;;
        D) DELETE_AFTER_UPLOAD_FLAG=1 ;;
        k) KEEP_LOCAL_FLAG=1 ;;
        n) DRY_RUN=1 ;;
        o) BACKUP_ROOT_OVERRIDE="$OPTARG" ;;
        r) RCLONE_REMOTE_OVERRIDE="$OPTARG" ;;
        d) DRIVE_DESTINATION_OVERRIDE="$OPTARG" ;;
        a) SINGLE_FILE="$OPTARG" ;;
        i) IGNORED_FOLDERS_OVERRIDE="$OPTARG" ;;
        *) echo "Usage: $0 [-v] [-p] [-s] [-D] [-k] [-n] [-o <origin>] [-r <rclone_remote>] [-d <drive_destination>] [-a <file>] [-i <ignored_folders>]"; exit 1 ;;
    esac
done

# ─────────────────────────────────────────────
# Configuration (from backup.env)
# ─────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
ENV_FILE="$SCRIPT_DIR/backup.env"

if [ ! -f "$ENV_FILE" ]; then
    echo "[ERROR] Configuration file $ENV_FILE not found." >&2
    exit 1
fi

# Load configuration
# shellcheck source=/dev/null
source "$ENV_FILE"

# Required variables validation
: "${BACKUP_ROOT:?Error: BACKUP_ROOT not defined in backup.env}"
: "${RCLONE_REMOTE:?Error: RCLONE_REMOTE not defined in backup.env}"

# Drive destination folder (e.g.: Backups)
DRIVE_DESTINATION="${DRIVE_DESTINATION:-Backups}"

# CLI overrides take priority over backup.env
if [ -n "$BACKUP_ROOT_OVERRIDE" ]; then
    BACKUP_ROOT="$BACKUP_ROOT_OVERRIDE"
fi
if [ -n "$RCLONE_REMOTE_OVERRIDE" ]; then
    RCLONE_REMOTE="$RCLONE_REMOTE_OVERRIDE"
fi
if [ -n "$DRIVE_DESTINATION_OVERRIDE" ]; then
    DRIVE_DESTINATION="$DRIVE_DESTINATION_OVERRIDE"
fi

# Log file defaults to the script directory if not set in .env
LOG_FILE="${LOG_FILE:-$SCRIPT_DIR/sync.log}"

# Folders to ignore (loaded from .env or safe defaults)
IGNORED_FOLDERS="${IGNORED_FOLDERS:-scripts config bin logs lost+found}"

# Append CLI-specified folders to the ignore list
if [ -n "$IGNORED_FOLDERS_OVERRIDE" ]; then
    IGNORED_FOLDERS="$IGNORED_FOLDERS $IGNORED_FOLDERS_OVERRIDE"
fi

# Skip dotfiles/dotfolders (default: false; -s flag sets to true)
SKIP_DOTFILES="${SKIP_DOTFILES:-false}"
[ "$SKIP_DOTFILES_FLAG" = "1" ] && SKIP_DOTFILES="true"

# What happens to the LOCAL files after a successful upload:
#   retention → delete files older than RETENTION_DAYS (default)
#   always    → delete every uploaded file, ignoring RETENTION_DAYS
#   never     → keep everything; the cloud copy is a duplicate, not a move
LOCAL_CLEANUP="${LOCAL_CLEANUP:-retention}"

# Back-compat: DELETE_AFTER_UPLOAD="true" (deprecated) means LOCAL_CLEANUP="always"
DEPRECATED_DELETE_AFTER_UPLOAD=0
if [ "${DELETE_AFTER_UPLOAD:-false}" = "true" ] && [ "$LOCAL_CLEANUP" = "retention" ]; then
    LOCAL_CLEANUP="always"
    DEPRECATED_DELETE_AFTER_UPLOAD=1
fi

# CLI overrides: -D deletes everything after upload, -k keeps everything
[ "$DELETE_AFTER_UPLOAD_FLAG" = "1" ] && LOCAL_CLEANUP="always"
[ "$KEEP_LOCAL_FLAG" = "1" ] && LOCAL_CLEANUP="never"

# Only used when LOCAL_CLEANUP="retention" (validated below)
RETENTION_DAYS="${RETENTION_DAYS:-}"

# Also upload files sitting directly in BACKUP_ROOT, outside any project folder (default: true)
UPLOAD_ROOT_FILES="${UPLOAD_ROOT_FILES:-true}"

UPLOAD_ERRORS=0
TOTAL_DELETED=0
DELETE_ERRORS=0
PROCESSED_COUNT=0
FAILED_PROJECTS=()
OVERALL_START=$(date +%s)

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

elapsed() {
    local start="$1"
    echo $(( $(date +%s) - start ))
}

rclone_log_level() {
    [ "$VERBOSE" = "1" ] && echo "DEBUG" || echo "NOTICE"
}

# Local cleanup, called ONLY after a successful upload. Applies LOCAL_CLEANUP:
# never (keeps everything), always (deletes all uploaded files) or retention
# (deletes files older than RETENTION_DAYS). Deletes nothing in dry-run mode.
# Usage: cleanup_local_files <path> [extra find filters...]
cleanup_local_files() {
    local path="$1"; shift
    local filter=(-maxdepth 1 -type f "$@")
    local deleted=0

    case "$LOCAL_CLEANUP" in
        never)
            log_verbose "   Local cleanup disabled (LOCAL_CLEANUP=never)."
            return 0
            ;;
        always)
            log_verbose "   Deleting all uploaded local files..."
            ;;
        *)
            log_verbose "   Cleaning local files older than $RETENTION_DAYS days..."
            filter+=(-mtime +"$RETENTION_DAYS")
            ;;
    esac

    # Dotfiles were excluded from the upload, so they must never be deleted here
    [ "$SKIP_DOTFILES" = "true" ] && filter+=(! -name ".*")

    while IFS= read -r -d '' file; do
        if [ "$DRY_RUN" = "1" ]; then
            log_verbose "   [dry-run] Would remove: $file"
            deleted=$((deleted + 1))
        elif rm -- "$file"; then
            deleted=$((deleted + 1))
        else
            log_warn "   ⚠ Could not delete: $file"
            DELETE_ERRORS=$((DELETE_ERRORS + 1))
        fi
    done < <(find "$path" "${filter[@]}" -print0)

    if [ "$deleted" -gt 0 ]; then
        if [ "$DRY_RUN" = "1" ]; then
            log_info "   [dry-run] Would remove $deleted local files."
        else
            log_info "   - Removed $deleted local files."
            TOTAL_DELETED=$((TOTAL_DELETED + deleted))
        fi
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
        send_error_email "$(notify_host): backup upload FAILED (exit $exit_code)" \
            "$(notify_body "The upload script terminated unexpectedly with exit code $exit_code.

Last log lines:
$(notify_log_tail 30)")"
    fi
}
trap cleanup_on_error EXIT

# ─────────────────────────────────────────────
# Initial validations
# ─────────────────────────────────────────────

if ! command -v rclone &>/dev/null; then
    log_error "rclone not found. Please install it before continuing."
    exit 1
fi

if [ "$DRY_RUN" = "1" ]; then
    log_warn "--- DRY-RUN MODE ENABLED: nothing will be uploaded or deleted ---"
fi

case "$LOCAL_CLEANUP" in
    retention)
        if [ -z "$RETENTION_DAYS" ]; then
            log_error "RETENTION_DAYS must be set in backup.env when LOCAL_CLEANUP=\"retention\"."
            exit 1
        fi
        ;;
    always|never) ;;
    *)
        log_error "Invalid LOCAL_CLEANUP: '$LOCAL_CLEANUP' (expected: retention, always or never)."
        exit 1
        ;;
esac

if [ "$DEPRECATED_DELETE_AFTER_UPLOAD" = "1" ]; then
    log_warn "DELETE_AFTER_UPLOAD is deprecated. Use LOCAL_CLEANUP=\"always\" in backup.env instead."
fi

# ─────────────────────────────────────────────
# Single file mode (-a)
# ─────────────────────────────────────────────

if [ -n "$SINGLE_FILE" ]; then
    if [ ! -f "$SINGLE_FILE" ]; then
        log_error "File not found: $SINGLE_FILE"
        exit 1
    fi

    log_info "Uploading single file: $SINGLE_FILE"
    RCLONE_FLAGS=("--log-level" "$(rclone_log_level)" "--retries" "3")
    [ "$SHOW_PROGRESS" = "1" ] && RCLONE_FLAGS+=("-P")
    [ "$SKIP_DOTFILES" = "true" ] && RCLONE_FLAGS+=("--exclude" ".*" "--exclude" ".*/**")
    [ "$DRY_RUN" = "1" ] && RCLONE_FLAGS+=("--dry-run")

    if rclone copy "$SINGLE_FILE" "${RCLONE_REMOTE}/${DRIVE_DESTINATION}/" "${RCLONE_FLAGS[@]}"; then
        log_info "✓ File uploaded successfully."
    else
        log_error "Failed to upload $SINGLE_FILE"
        send_error_email "$(notify_host): single file upload FAILED" \
            "$(notify_body "Failed to upload single file: $SINGLE_FILE
Destination: ${RCLONE_REMOTE}/${DRIVE_DESTINATION}/

Last log lines:
$(notify_log_tail 20)")"
        trap - EXIT
        exit 1
    fi

    trap - EXIT
    exit 0
fi

# ─────────────────────────────────────────────
# Default mode (projects)
# ─────────────────────────────────────────────

if [ ! -d "$BACKUP_ROOT" ]; then
    log_error "Backup root directory not found: $BACKUP_ROOT"
    exit 1
fi

log_info "Starting backup synchronization..."
log_info "Settings: root=$BACKUP_ROOT | remote=$RCLONE_REMOTE | local_cleanup=$LOCAL_CLEANUP${RETENTION_DAYS:+ (${RETENTION_DAYS}d)} | skip_dotfiles=$SKIP_DOTFILES | upload_root_files=$UPLOAD_ROOT_FILES"

# ─────────────────────────────────────────────
# Processing per Project
# ─────────────────────────────────────────────

# Loop through each subdirectory in the backup root
# Using nullglob to avoid errors if the directory is empty
shopt -s nullglob
for project_path in "$BACKUP_ROOT"/*; do
    # Skip if not a directory
    [ -d "$project_path" ] || continue

    PROJECT_NAME=$(basename "$project_path")

    # SAFETY: Skip folders that are not backup projects
    # Ignores hidden folders (starting with .) and folders defined in IGNORED_FOLDERS
    if [[ "$PROJECT_NAME" == .* ]] || [[ " ${IGNORED_FOLDERS} " == *" ${PROJECT_NAME} "* ]]; then
        log_verbose "   - Skipping ignored/reserved folder: $PROJECT_NAME"
        continue
    fi

    log_info "→ Processing project: $PROJECT_NAME"
    PROCESSED_COUNT=$((PROCESSED_COUNT + 1))
    STEP_START=$(date +%s)

    # 1. Upload to Drive (organized by project folder)
    RCLONE_FLAGS=("--log-level" "$(rclone_log_level)" "--stats-one-line" "--stats" "10s" "--update" "--use-mmap" "--retries" "3")
    [ "$SHOW_PROGRESS" = "1" ] && RCLONE_FLAGS+=("-P")
    [ "$SKIP_DOTFILES" = "true" ] && RCLONE_FLAGS+=("--exclude" ".*" "--exclude" ".*/**")
    [ "$DRY_RUN" = "1" ] && RCLONE_FLAGS+=("--dry-run")

    if rclone copy "$project_path" "${RCLONE_REMOTE}/${DRIVE_DESTINATION}/${PROJECT_NAME}" \
        "${RCLONE_FLAGS[@]}"; then

        log_info "   ✓ Synchronized successfully."

        # 2. Local cleanup (ONLY after successful upload)
        cleanup_local_files "$project_path"
    else
        log_warn "   ⚠ Sync failed for project $PROJECT_NAME. Local cleanup SKIPPED."
        UPLOAD_ERRORS=$((UPLOAD_ERRORS + 1))
        FAILED_PROJECTS+=("$PROJECT_NAME")
    fi

    log_verbose "   Project time: $(elapsed $STEP_START)s"
done
shopt -u nullglob

# ─────────────────────────────────────────────
# Loose files in the backup root
# ─────────────────────────────────────────────

# Files sitting directly in BACKUP_ROOT (not inside a project folder) are uploaded
# to the destination root. The active log file is always excluded so it is never
# uploaded half-written nor deleted by the retention cleanup.
if [ "$UPLOAD_ROOT_FILES" = "true" ]; then

    # Detection filter: is there any loose file worth uploading?
    ROOT_FIND_FILTER=(-maxdepth 1 -type f ! -name "$(basename "$LOG_FILE")")
    [ "$SKIP_DOTFILES" = "true" ] && ROOT_FIND_FILTER+=(! -name ".*")

    if [ -n "$(find "$BACKUP_ROOT" "${ROOT_FIND_FILTER[@]}" -print -quit)" ]; then
        log_info "→ Processing loose files in backup root"
        PROCESSED_COUNT=$((PROCESSED_COUNT + 1))
        STEP_START=$(date +%s)

        # --max-depth 1 keeps the project folders out of this upload
        RCLONE_FLAGS=("--log-level" "$(rclone_log_level)" "--stats-one-line" "--stats" "10s" "--update" "--use-mmap" "--retries" "3" "--max-depth" "1")
        [ "$SHOW_PROGRESS" = "1" ] && RCLONE_FLAGS+=("-P")
        [ "$SKIP_DOTFILES" = "true" ] && RCLONE_FLAGS+=("--exclude" ".*" "--exclude" ".*/**")
        RCLONE_FLAGS+=("--exclude" "/$(basename "$LOG_FILE")")
        [ "$DRY_RUN" = "1" ] && RCLONE_FLAGS+=("--dry-run")

        if rclone copy "$BACKUP_ROOT" "${RCLONE_REMOTE}/${DRIVE_DESTINATION}/" \
            "${RCLONE_FLAGS[@]}"; then

            log_info "   ✓ Synchronized successfully."

            # Local cleanup (ONLY after successful upload), never the log file
            cleanup_local_files "$BACKUP_ROOT" ! -name "$(basename "$LOG_FILE")"
        else
            log_warn "   ⚠ Sync failed for loose files in backup root. Local cleanup SKIPPED."
            UPLOAD_ERRORS=$((UPLOAD_ERRORS + 1))
            FAILED_PROJECTS+=("(root files)")
        fi

        log_verbose "   Loose files time: $(elapsed $STEP_START)s"
    fi
fi

# ─────────────────────────────────────────────
# Final Summary
# ─────────────────────────────────────────────

TOTAL_DURATION=$(elapsed $OVERALL_START)

# EMPTY means nothing was found to upload — almost always a misconfigured
# BACKUP_ROOT, an unmounted disk, or the scripts that generate the backups
# having stopped. It must never be reported as a success.
if [ "$UPLOAD_ERRORS" -gt 0 ]; then
    STATUS="PARTIAL"
elif [ "$PROCESSED_COUNT" -eq 0 ]; then
    STATUS="EMPTY"
else
    STATUS="SUCCESS"
fi

log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [ "$STATUS" = "EMPTY" ]; then
    log_warn "⚠ Nothing to upload — no project folders or loose files found in $BACKUP_ROOT (${TOTAL_DURATION}s)"
else
    log_info "✅ Synchronization completed in ${TOTAL_DURATION}s"
fi

# Summary block for the log (always at the end)
{
    echo "════════════════════════════════════════════════"
    echo "  SYNC SUMMARY — $(date '+%Y-%m-%d %H:%M:%S')"
    echo "════════════════════════════════════════════════"
    echo "  Status            : $STATUS"
    echo "  Duration          : ${TOTAL_DURATION}s"
    echo "  Cloud Destination : ${RCLONE_REMOTE}/${DRIVE_DESTINATION}/"
    echo "  Items Processed   : $PROCESSED_COUNT"
    echo "  Projects w/ Errors: $UPLOAD_ERRORS"
    echo "  Files Removed (Local): $TOTAL_DELETED"
    echo "  Delete Errors     : $DELETE_ERRORS"
    echo "  --- Flags ---"
    echo "  skip_dotfiles     : $SKIP_DOTFILES"
    echo "  local_cleanup     : $LOCAL_CLEANUP"
    echo "  retention_days    : ${RETENTION_DAYS:-n/a}"
    echo "  dry_run           : $DRY_RUN"
    echo "════════════════════════════════════════════════"
    echo ""
} >> "$LOG_FILE"

# Error notification (single aggregated e-mail per run)
if [ "$STATUS" = "EMPTY" ]; then
    send_error_email "$(notify_host): backup sync found NOTHING to upload" \
        "$(notify_body "No project folder or loose file was found in the backup root,
so NOTHING was uploaded on this run.

This usually means the backup root is misconfigured, the disk is not mounted,
or the scripts that generate the backups have stopped running.

Backup root       : $BACKUP_ROOT
Cloud destination : ${RCLONE_REMOTE}/${DRIVE_DESTINATION}/
Ignored folders   : $IGNORED_FOLDERS
Upload root files : $UPLOAD_ROOT_FILES

Last log lines:
$(notify_log_tail 30)")"
elif [ "$UPLOAD_ERRORS" -gt 0 ]; then
    send_error_email "$(notify_host): backup sync $STATUS ($UPLOAD_ERRORS project(s) failed)" \
        "$(notify_body "Status              : $STATUS
Duration            : ${TOTAL_DURATION}s
Cloud destination   : ${RCLONE_REMOTE}/${DRIVE_DESTINATION}/
Projects with errors: $UPLOAD_ERRORS
Failed projects     : ${FAILED_PROJECTS[*]}
Files removed (local): $TOTAL_DELETED
Delete errors       : $DELETE_ERRORS

Local cleanup was SKIPPED for the failed projects, so no data was lost locally.

Last log lines:
$(notify_log_tail 30)")"
fi

# Remove error trap for clean exit
trap - EXIT

if [ "$UPLOAD_ERRORS" -gt 0 ] || [ "$STATUS" = "EMPTY" ]; then
    exit 1
fi
exit 0
