#!/usr/bin/env bash
# deepseek-cursor-tunnel-health.sh
# Rebuild the Quick Tunnel when the public URL is missing or unreachable.
set -euo pipefail

CACHE_DIR="${HOME}/.cache/deepseek-cursor-proxy"
CURRENT_FILE="${CACHE_DIR}/current-base-url.txt"
LOCK_FILE="${CACHE_DIR}/tunnel-health.lock"

log_info()  { echo "[INFO]  $*"; }
log_warn()  { echo "[WARN]  $*" >&2; }

ensure_lock() {
    mkdir -p "$CACHE_DIR"

    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        log_info "Another tunnel-health run is already in progress. Exiting."
        exit 0
    fi
}

current_url_works() {
    local url=""
    [[ -f "$CURRENT_FILE" ]] || return 1
    url="$(tr -d '\r\n' < "$CURRENT_FILE")"
    [[ -n "$url" ]] || return 1
    curl -fsS --max-time 15 "${url}/models" >/dev/null 2>&1
}

main() {
    ensure_lock

    if systemctl --user is-active deepseek-cursor-boot-prepare.service >/dev/null 2>&1; then
        log_info "boot-prepare is already running. Exiting."
        exit 0
    fi

    if current_url_works; then
        log_info "Tunnel URL is healthy: $(tr -d '\r\n' < "$CURRENT_FILE")"
        exit 0
    fi

    log_warn "Tunnel URL missing or unreachable. Triggering full rebuild..."
    systemctl --user start deepseek-cursor-boot-prepare.service
    exit 0
}

main "$@"
