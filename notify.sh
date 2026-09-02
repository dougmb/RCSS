#!/usr/bin/env bash
# E-mail notification helper — shared by uploadBackup.sh and cleanRemoteBackups.sh.
#
# This file is meant to be SOURCED, after backup.env has been loaded and after the
# log_* helpers are defined (it uses log_info / log_warn from the calling script).
#
# Everything is configured in backup.env. An empty NOTIFY_EMAIL_TO disables the
# feature completely, so scripts behave exactly as before when it is not set up.

# Hostname used to identify which server raised the alert.
notify_host() {
    echo "${HOSTNAME:-$(uname -n)}"
}

# Last lines of the log file, used to give context in the alert body.
notify_log_tail() {
    local lines="${1:-30}"
    if [ -n "${LOG_FILE:-}" ] && [ -f "$LOG_FILE" ]; then
        tail -n "$lines" "$LOG_FILE"
    else
        echo "(log file unavailable)"
    fi
}

# Standard alert body: identification header + the details passed in.
# Usage: notify_body "<details>"
notify_body() {
    printf 'Host      : %s\nScript    : %s\nTimestamp : %s\nLog file  : %s\n' \
        "$(notify_host)" \
        "${SCRIPT_NAME:-unknown}" \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "${LOG_FILE:-n/a}"

    # Makes it obvious that an alert came from a test run, not from production
    [ "${DRY_RUN:-0}" = "1" ] && printf 'Mode      : DRY-RUN (nothing was uploaded or deleted)\n'

    printf '\n%s\n' "$1"
}

# Sends an error alert by e-mail via SMTP (curl).
# Never interrupts the calling script: any problem is logged as a warning only.
# Usage: send_error_email "<subject>" "<body>"
send_error_email() {
    local subject="$1"
    local body="$2"

    # Feature disabled: no destination configured in backup.env
    [ -n "${NOTIFY_EMAIL_TO:-}" ] || return 0

    if [ -z "${SMTP_HOST:-}" ]; then
        log_warn "NOTIFY_EMAIL_TO is set but SMTP_HOST is empty. E-mail notification skipped."
        return 0
    fi

    if ! command -v curl &>/dev/null; then
        log_warn "curl not found. E-mail notification skipped."
        return 0
    fi

    local from="${NOTIFY_EMAIL_FROM:-$NOTIFY_EMAIL_TO}"
    local prefix="${NOTIFY_SUBJECT_PREFIX:-[RCSS]}"
    [ "${DRY_RUN:-0}" = "1" ] && prefix="$prefix [DRY-RUN]"
    local port="${SMTP_PORT:-587}"

    local message
    message=$(printf 'From: %s\nTo: %s\nSubject: %s %s\nDate: %s\n\n%s\n' \
        "$from" "$NOTIFY_EMAIL_TO" "$prefix" "$subject" "$(date -R)" "$body")

    local curl_flags=(
        --silent --show-error
        --url "smtp://${SMTP_HOST}:${port}"
        --ssl-reqd
        --mail-from "$from"
        --mail-rcpt "$NOTIFY_EMAIL_TO"
        --upload-file -
    )
    [ -n "${SMTP_USER:-}" ] && curl_flags+=(--user "${SMTP_USER}:${SMTP_PASSWORD:-}")

    if printf '%s' "$message" | curl "${curl_flags[@]}" >/dev/null 2>&1; then
        log_info "E-mail notification sent to $NOTIFY_EMAIL_TO"
    else
        log_warn "Failed to send e-mail notification to $NOTIFY_EMAIL_TO (check SMTP_* settings in backup.env)."
    fi
}
