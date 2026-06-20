#!/usr/bin/env bash
# deepseek-cursor-resume-recover.sh
# Rebuild Quick Tunnel after system resume when cloudflared session is stale.
set -euo pipefail

CACHE_DIR="${HOME}/.cache/deepseek-cursor-proxy"
LOCK_FILE="${CACHE_DIR}/resume-recover.lock"

log_info()  { echo "[INFO]  $*"; }
log_warn()  { echo "[WARN]  $*" >&2; }

ensure_lock() {
    mkdir -p "$CACHE_DIR"

    exec 9>"$LOCK_FILE"
    if ! flock -n 9; then
        log_info "Another resume-recover run is already in progress (lock held). Exiting."
        exit 0
    fi
}

main() {
    ensure_lock

    log_info "Resume recovery starting; waiting for network/session to stabilize..."
    sleep 5

    if command -v nm-online >/dev/null 2>&1; then
        nm-online -q -t 30 || true
    fi

    log_info "Checking local proxy on http://127.0.0.1:9000/v1/models..."
    if ! curl -fsS --max-time 5 http://127.0.0.1:9000/v1/models >/dev/null 2>&1; then
        log_warn "Local proxy not ready; restarting deepseek-cursor-proxy.service..."
        systemctl --user restart deepseek-cursor-proxy.service
    fi

    log_info "Restarting cloudflared Quick Tunnel after resume..."
    systemctl --user restart cloudflared-deepseek-quick.service

    log_info "Starting deepseek-cursor-boot-prepare.service..."
    systemctl --user start deepseek-cursor-boot-prepare.service || true

    log_info "Resume recovery triggered. Current service status:"
    systemctl --user status cloudflared-deepseek-quick.service --no-pager || true
    systemctl --user status update-cursor-deepseek-url.timer --no-pager || true
    systemctl --user status deepseek-cursor-pending-watcher.path --no-pager || true

    log_info "Resume recovery complete."
    exit 0
}

main "$@"
