#!/usr/bin/env bash
# deepseek-cursor-pending-watcher.sh
# Triggered by systemd path unit when pending-base-url.txt appears.
# Waits for Cursor to exit, then runs the URL updater immediately.
set -euo pipefail

CACHE_DIR="${HOME}/.cache/deepseek-cursor-proxy"
PENDING_FILE="${CACHE_DIR}/pending-base-url.txt"
LOCK_FILE="${CACHE_DIR}/pending-watcher.lock"
UPDATER_BIN="${HOME}/.local/bin/update-cursor-deepseek-url"
MAX_WAIT_SEC=28800   # 8 hours
POLL_INTERVAL=5
EXIT_TEMPFAIL=75

log_info()  { echo "[INFO]  $*"; }
log_warn()  { echo "[WARN]  $*" >&2; }
log_error() { echo "[ERROR] $*" >&2; }

cursor_is_running() {
    ps -eo pid=,args= | awk '/\/usr\/share\/cursor\/cursor([[:space:]]|$)/ { found=1 } END { exit found ? 0 : 1 }'
}

ensure_lock() {
    mkdir -p "$CACHE_DIR"

    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        log_info "Another pending-watcher is already running (lock held). Exiting."
        exit 0
    fi
}

main() {
    ensure_lock

    if [[ ! -f "$PENDING_FILE" ]]; then
        log_info "No pending-base-url.txt found. Nothing to do."
        exit 0
    fi

    local pending_url=""
    pending_url="$(tr -d '\r\n' < "$PENDING_FILE")"
    if [[ -z "$pending_url" ]]; then
        log_warn "pending-base-url.txt is empty; removing."
        rm -f "$PENDING_FILE"
        exit 0
    fi

    log_info "Pending URL: $pending_url"

    if ! cursor_is_running; then
        log_info "Cursor is not running. Running updater immediately..."
        if [[ -x "$UPDATER_BIN" ]]; then
            "$UPDATER_BIN"
        else
            log_error "Updater binary not found: $UPDATER_BIN"
            exit 1
        fi
        exit 0
    fi

    log_info "Cursor is running. Waiting for it to exit (max ${MAX_WAIT_SEC}s, poll every ${POLL_INTERVAL}s)..."

    local elapsed=0
    while [[ $elapsed -lt $MAX_WAIT_SEC ]]; do
        sleep "$POLL_INTERVAL"
        elapsed=$((elapsed + POLL_INTERVAL))

        if ! cursor_is_running; then
            log_info "Cursor exited after ~${elapsed}s. Running updater..."
            if [[ -x "$UPDATER_BIN" ]]; then
                "$UPDATER_BIN"
            else
                log_error "Updater binary not found: $UPDATER_BIN"
                exit 1
            fi
            exit 0
        fi
    done

    log_warn "Timeout (${MAX_WAIT_SEC}s) reached. Cursor is still running."
    log_warn "Keeping pending-base-url.txt; the periodic timer will retry."
    exit "$EXIT_TEMPFAIL"
}

main "$@"
