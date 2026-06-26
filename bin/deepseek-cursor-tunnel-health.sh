#!/usr/bin/env bash
# deepseek-cursor-tunnel-health.sh
# Rebuild the Quick Tunnel only when cloudflared or the active tunnel URL is dead.
set -euo pipefail

CACHE_DIR="${HOME}/.cache/deepseek-cursor-proxy"
CURRENT_FILE="${CACHE_DIR}/current-base-url.txt"
CLOUDFLARED_LOG="${CACHE_DIR}/cloudflared.log"
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

latest_tunnel_url() {
    grep -oE 'https://[-a-z0-9]+\.trycloudflare\.com' "$CLOUDFLARED_LOG" 2>/dev/null | tail -1 | sed 's|/$||' || true
}

tunnel_url_is_live() {
    local url="$1"
    [[ -n "$url" ]] || return 1
    curl -fsS --max-time 15 "${url}/v1/models" >/dev/null 2>&1
}

current_url_works() {
    local url=""
    [[ -f "$CURRENT_FILE" ]] || return 1
    url="$(tr -d '\r\n' < "$CURRENT_FILE")"
    [[ -n "$url" ]] || return 1
    curl -fsS --max-time 15 "${url}/models" >/dev/null 2>&1
}

active_tunnel_is_healthy() {
    systemctl --user is-active deepseek-cursor-proxy.service >/dev/null 2>&1 || return 1
    curl -fsS --max-time 10 http://127.0.0.1:9000/v1/models >/dev/null 2>&1 || return 1
    systemctl --user is-active cloudflared-deepseek-quick.service >/dev/null 2>&1 || return 1
    [[ -f "$CLOUDFLARED_LOG" ]] || return 1
    grep -q 'Registered tunnel connection' "$CLOUDFLARED_LOG" 2>/dev/null || return 1
    tunnel_url_is_live "$(latest_tunnel_url)"
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

    if active_tunnel_is_healthy; then
        local live_url=""
        live_url="$(latest_tunnel_url)"
        log_info "Active tunnel is healthy but Cursor URL file is stale: $live_url"
        log_info "Running URL updater without restarting cloudflared..."
        if [[ -x "${HOME}/.local/bin/update-cursor-deepseek-url" ]]; then
            "${HOME}/.local/bin/update-cursor-deepseek-url" || true
        else
            systemctl --user start update-cursor-deepseek-url.service || true
        fi
        exit 0
    fi

    log_warn "Tunnel unhealthy. Triggering rebuild..."
    systemctl --user start deepseek-cursor-boot-prepare.service
    exit 0
}

main "$@"
