#!/usr/bin/env bash
# deepseek-cursor-boot-prepare.sh
# Rebuild Quick Tunnel at login and patch Cursor DB via the updater service.
set -euo pipefail

CACHE_DIR="${HOME}/.cache/deepseek-cursor-proxy"
CLOUDFLARED_LOG="${CACHE_DIR}/cloudflared.log"
CURRENT_FILE="${CACHE_DIR}/current-base-url.txt"
PENDING_FILE="${CACHE_DIR}/pending-base-url.txt"
STALE_FILE="${CACHE_DIR}/stale-base-url.txt"

WAIT_LOG_MAX_SEC=60
WAIT_LOG_INTERVAL=2
WAIT_URL_IN_LOG_MAX_SEC=60
WAIT_URL_IN_LOG_INTERVAL=2
WAIT_REGISTERED_MAX_SEC=120
WAIT_REGISTERED_INTERVAL=2
WAIT_DOH_MAX_SEC=90
WAIT_DOH_INTERVAL=3
WAIT_SYSTEM_DNS_MAX_SEC=120
WAIT_SYSTEM_DNS_INTERVAL=3
WAIT_HTTP_MAX_SEC=120
WAIT_HTTP_INTERVAL=3
WAIT_UPDATER_MAX_SEC=120
WAIT_UPDATER_INTERVAL=3
MAX_TUNNEL_ATTEMPTS=3
EXIT_TEMPFAIL=75
EXIT_ROUTER_DNS_STALE=2

LAST_TUNNEL_URL=""
LAST_TUNNEL_HOST=""
DNS_DOH_GATE_PASSED=false

log_info()  { echo "[INFO]  $*"; }
log_warn()  { echo "[WARN]  $*" >&2; }
log_error() { echo "[ERROR] $*" >&2; }

cleanup() {
    systemctl --user restart update-cursor-deepseek-url.timer >/dev/null 2>&1 || true
}

host_from_url() {
    local url="$1"
    url="${url#https://}"
    url="${url#http://}"
    printf '%s' "${url%%/*}"
}

host_resolves() {
    local host="$1"
    if [[ "$DNS_DOH_GATE_PASSED" != true ]]; then
        log_error "Internal error: system DNS queried for $host before Cloudflare DoH gate passed."
        return 1
    fi
    if getent hosts "$host" >/dev/null 2>&1; then
        return 0
    fi
    if command -v resolvectl &>/dev/null; then
        resolvectl query "$host" >/dev/null 2>&1 && return 0
    fi
    return 1
}

cloudflare_doh_resolves() {
    local host="$1"

    command -v curl >/dev/null 2>&1 || return 1

    local response=""
    response="$(curl -fsS --max-time 8 \
        "https://cloudflare-dns.com/dns-query?name=${host}&type=A" \
        -H 'accept: application/dns-json' 2>/dev/null || true)"

    [[ -n "$response" ]] || return 1
    echo "$response" | grep -q '"Status"[[:space:]]*:[[:space:]]*0' || return 1
    echo "$response" | grep -q '"Answer"' || return 1
    echo "$response" | grep -Eq '"data"[[:space:]]*:[[:space:]]*"([0-9]{1,3}\.){3}[0-9]{1,3}"'
}

wait_for_cloudflare_doh() {
    local host="$1"
    local elapsed=0

    log_info "Waiting for Cloudflare DoH publication of $host before touching system DNS..."

    while [[ $elapsed -lt $WAIT_DOH_MAX_SEC ]]; do
        if cloudflare_doh_resolves "$host"; then
            DNS_DOH_GATE_PASSED=true
            log_info "Cloudflare DoH resolves $host after ${elapsed}s."
            return 0
        fi

        sleep "$WAIT_DOH_INTERVAL"
        elapsed=$((elapsed + WAIT_DOH_INTERVAL))
    done

    log_warn "Cloudflare DoH did not resolve $host after ${WAIT_DOH_MAX_SEC}s; treating tunnel URL as not published yet."
    return 1
}

wait_for_system_dns_after_doh() {
    local host="$1"
    local elapsed=0

    log_info "Waiting up to ${WAIT_SYSTEM_DNS_MAX_SEC}s for system DNS to catch up..."
    if host_resolves "$host"; then
        log_info "System resolver confirms $host."
        return 0
    fi

    resolvectl flush-caches >/dev/null 2>&1 || true

    while [[ $elapsed -lt $WAIT_SYSTEM_DNS_MAX_SEC ]]; do
        if host_resolves "$host"; then
            log_info "System resolver confirms $host."
            return 0
        fi
        sleep "$WAIT_SYSTEM_DNS_INTERVAL"
        elapsed=$((elapsed + WAIT_SYSTEM_DNS_INTERVAL))
    done

    log_error "Cloudflare DoH resolves $host, but system resolver still returns NXDOMAIN/stale result."
    log_error "Router DNS may have negative-cached this hostname."
    return "$EXIT_ROUTER_DNS_STALE"
}

current_url_works() {
    local url=""
    [[ -f "$CURRENT_FILE" ]] || return 1
    url="$(tr -d '\r\n' < "$CURRENT_FILE")"
    [[ -n "$url" ]] || return 1
    curl -fsS --max-time 15 "${url}/models" >/dev/null 2>&1
}

latest_tunnel_url() {
    grep -oE 'https://[-a-z0-9]+\.trycloudflare\.com' "$CLOUDFLARED_LOG" 2>/dev/null | tail -1 || true
}

wait_for_fresh_cloudflared_log() {
    local elapsed=0
    local wait_delete=0

    while [[ -f "$CLOUDFLARED_LOG" && $wait_delete -lt 20 ]]; do
        sleep 0.2
        wait_delete=$((wait_delete + 1))
    done

    log_info "Waiting for cloudflared log..."
    while [[ $elapsed -lt $WAIT_LOG_MAX_SEC ]]; do
        if [[ -f "$CLOUDFLARED_LOG" ]]; then
            if [[ $elapsed -eq 0 ]]; then
                log_info "Cloudflared log ready."
            else
                log_info "Cloudflared log appeared after ${elapsed}s."
            fi
            return 0
        fi
        sleep "$WAIT_LOG_INTERVAL"
        elapsed=$((elapsed + WAIT_LOG_INTERVAL))
    done

    log_error "Cloudflared log not found: $CLOUDFLARED_LOG"
    return 1
}

wait_for_tunnel_url_in_log() {
    local url=""
    local elapsed=0

    log_info "Waiting for Quick Tunnel URL in cloudflared log (up to ${WAIT_URL_IN_LOG_MAX_SEC}s)..."
    while [[ $elapsed -lt $WAIT_URL_IN_LOG_MAX_SEC ]]; do
        url="$(latest_tunnel_url)"
        if [[ -n "$url" ]]; then
            LAST_TUNNEL_URL="${url%/}"
            LAST_TUNNEL_HOST="$(host_from_url "$LAST_TUNNEL_URL")"
            log_info "Quick Tunnel URL from log: $LAST_TUNNEL_URL"
            return 0
        fi
        sleep "$WAIT_URL_IN_LOG_INTERVAL"
        elapsed=$((elapsed + WAIT_URL_IN_LOG_INTERVAL))
    done

    log_warn "No Quick Tunnel URL found in cloudflared log within ${WAIT_URL_IN_LOG_MAX_SEC}s."
    return 1
}

wait_for_tunnel_registered() {
    local elapsed=0

    log_info "Waiting for Registered tunnel connection in cloudflared log..."
    while [[ $elapsed -lt $WAIT_REGISTERED_MAX_SEC ]]; do
        if grep -q 'Registered tunnel connection' "$CLOUDFLARED_LOG" 2>/dev/null; then
            if [[ $elapsed -gt 0 ]]; then
                log_info "Registered tunnel connection seen after ${elapsed}s."
            else
                log_info "Registered tunnel connection seen."
            fi
            return 0
        fi
        sleep "$WAIT_REGISTERED_INTERVAL"
        elapsed=$((elapsed + WAIT_REGISTERED_INTERVAL))
    done

    log_warn "Registered tunnel connection not seen within ${WAIT_REGISTERED_MAX_SEC}s."
    return 1
}

wait_for_tunnel_http() {
    local url="$1"
    local elapsed=0
    local health_ok=false
    local models_ok=false

    url="${url%/}"
    log_info "Waiting for HTTP readiness..."
    while [[ $elapsed -lt $WAIT_HTTP_MAX_SEC ]]; do
        health_ok=false
        models_ok=false
        if curl -fsS --max-time 10 "${url}/healthz" >/dev/null 2>&1; then
            health_ok=true
        fi
        if curl -fsS --max-time 10 "${url}/v1/models" >/dev/null 2>&1; then
            models_ok=true
        fi
        if [[ "$health_ok" == true && "$models_ok" == true ]]; then
            log_info "/healthz ready"
            log_info "/v1/models ready"
            return 0
        fi
        sleep "$WAIT_HTTP_INTERVAL"
        elapsed=$((elapsed + WAIT_HTTP_INTERVAL))
    done

    log_warn "Tunnel HTTP checks failed after ${WAIT_HTTP_MAX_SEC}s: $url"
    return 1
}

verify_try_one_tunnel_dns_order() {
    local script_path="$0"
    local block=""
    local doh_line=""
    local sys_line=""

    block="$(sed -n '/^try_one_tunnel() {/,/^}/p' "$script_path")"
    [[ -n "$block" ]] || {
        log_error "Self-check failed: could not extract try_one_tunnel() from $script_path"
        exit 1
    }

    if echo "$block" | grep -qE 'Waiting for system DNS resolution|Candidate DNS not resolvable'; then
        log_error "Self-check failed: legacy DNS-first log strings still present in try_one_tunnel()."
        exit 1
    fi

    doh_line="$(echo "$block" | grep -n 'wait_for_cloudflare_doh' | head -1 | cut -d: -f1 || true)"
    sys_line="$(echo "$block" | grep -nE 'wait_for_system_dns_after_doh|host_resolves.*LAST_TUNNEL_HOST' | head -1 | cut -d: -f1 || true)"

    if [[ -z "$doh_line" || -z "$sys_line" ]]; then
        log_error "Self-check failed: could not locate DoH/system DNS calls in try_one_tunnel()."
        exit 1
    fi

    if [[ "$sys_line" -lt "$doh_line" ]]; then
        log_error "Self-check failed: system DNS is referenced before Cloudflare DoH in try_one_tunnel()."
        exit 1
    fi
}

try_one_tunnel() {
    local attempt="$1"
    local url=""
    local dns_result=0

    DNS_DOH_GATE_PASSED=false

    log_info "Restarting cloudflared-deepseek-quick.service..."
    systemctl --user restart cloudflared-deepseek-quick.service

    if ! wait_for_fresh_cloudflared_log; then
        log_warn "Tunnel attempt ${attempt}/${MAX_TUNNEL_ATTEMPTS}: cloudflared log missing."
        return 1
    fi

    if ! wait_for_tunnel_url_in_log; then
        log_warn "Tunnel attempt ${attempt}/${MAX_TUNNEL_ATTEMPTS}: no URL in log."
        return 1
    fi

    if ! wait_for_tunnel_registered; then
        log_warn "Tunnel attempt ${attempt}/${MAX_TUNNEL_ATTEMPTS}: tunnel not registered."
        return 1
    fi

    url="$LAST_TUNNEL_URL"
    LAST_TUNNEL_HOST="$(host_from_url "$url")"

    if ! wait_for_cloudflare_doh "$LAST_TUNNEL_HOST"; then
        log_warn "Tunnel attempt ${attempt}/${MAX_TUNNEL_ATTEMPTS}: Cloudflare DoH not ready for $LAST_TUNNEL_HOST."
        return 1
    fi

    dns_result=0
    wait_for_system_dns_after_doh "$LAST_TUNNEL_HOST" || dns_result=$?
    if [[ $dns_result -eq "$EXIT_ROUTER_DNS_STALE" ]]; then
        return "$EXIT_ROUTER_DNS_STALE"
    fi
    if [[ $dns_result -ne 0 ]]; then
        log_warn "Tunnel attempt ${attempt}/${MAX_TUNNEL_ATTEMPTS}: system DNS failed for $LAST_TUNNEL_HOST."
        return 1
    fi

    if wait_for_tunnel_http "$url"; then
        LAST_TUNNEL_URL="$url"
        return 0
    fi

    log_warn "Tunnel attempt ${attempt}/${MAX_TUNNEL_ATTEMPTS}: HTTP checks failed for $url."
    return 1
}

try_tunnel_attempts() {
    local attempt=1
    local result=0

    for (( attempt=1; attempt<=MAX_TUNNEL_ATTEMPTS; attempt++ )); do
        log_info "Tunnel attempt ${attempt}/${MAX_TUNNEL_ATTEMPTS}"
        result=0
        try_one_tunnel "$attempt" || result=$?
        if [[ $result -eq 0 ]]; then
            return 0
        fi
        if [[ $result -eq "$EXIT_ROUTER_DNS_STALE" ]]; then
            return "$EXIT_ROUTER_DNS_STALE"
        fi
    done

    log_error "All ${MAX_TUNNEL_ATTEMPTS} Quick Tunnel attempts failed."
    return 1
}

wait_for_updater_result() {
    local elapsed=0

    log_info "Waiting for updater result (up to ${WAIT_UPDATER_MAX_SEC}s)..."
    while [[ $elapsed -lt $WAIT_UPDATER_MAX_SEC ]]; do
        if current_url_works; then
            log_info "Verified current-base-url: $(tr -d '\r\n' < "$CURRENT_FILE")"
            return 0
        fi
        if [[ -f "$PENDING_FILE" ]]; then
            log_warn "Pending tunnel URL written: $(tr -d '\r\n' < "$PENDING_FILE")"
            log_warn "Cursor is running; close Cursor and the retry timer will patch state.vscdb."
            return "$EXIT_TEMPFAIL"
        fi
        sleep "$WAIT_UPDATER_INTERVAL"
        elapsed=$((elapsed + WAIT_UPDATER_INTERVAL))
    done

    log_error "Updater did not produce current or pending URL within ${WAIT_UPDATER_MAX_SEC}s."
    return 1
}

print_dns_diagnostics() {
    local host="${1:-$LAST_TUNNEL_HOST}"
    if [[ -z "$host" ]]; then
        echo "dns host: (none)"
        return 0
    fi

    echo "dns host: $host"
    echo "Cloudflare DoH (https://cloudflare-dns.com/dns-query):"
    if cloudflare_doh_resolves "$host"; then
        echo "ok (Status 0 with A records)"
    else
        curl -fsS --max-time 8 \
            "https://cloudflare-dns.com/dns-query?name=${host}&type=A" \
            -H 'accept: application/dns-json' 2>&1 || echo "(Cloudflare DoH: not resolved)"
    fi
    echo "getent hosts (system resolver):"
    getent hosts "$host" 2>&1 || echo "(getent: not resolved)"
    if command -v resolvectl &>/dev/null; then
        echo "resolvectl query (system resolver):"
        resolvectl query "$host" 2>&1 || echo "(resolvectl: not resolved)"
    fi
    if command -v dig &>/dev/null; then
        echo "dig +short (informational):"
        dig +short "$host" 2>&1 || true
        echo "dig +short @1.1.1.1 (informational only; may timeout with DNS-over-TLS firewall):"
        dig +short @1.1.1.1 "$host" 2>&1 || echo "(dig @1.1.1.1 timed out or failed; not a readiness failure)"
    else
        echo "dig: (not installed)"
    fi
}

print_diagnostics() {
    echo ""
    log_error "=== Diagnostics ==="
    systemctl --user status deepseek-cursor-proxy --no-pager -l 2>&1 || true
    echo ""
    systemctl --user status cloudflared-deepseek-quick --no-pager -l 2>&1 || true
    echo ""
    systemctl --user status update-cursor-deepseek-url --no-pager -l 2>&1 || true
    echo ""
    systemctl --user status update-cursor-deepseek-url.timer --no-pager -l 2>&1 || true
    echo ""
    log_error "Latest cloudflared log URLs:"
    grep -oE 'https://[-a-z0-9]+\.trycloudflare\.com' "$CLOUDFLARED_LOG" 2>/dev/null | tail -5 || echo "(none)"
    echo ""
    echo "latest host: ${LAST_TUNNEL_HOST:-none}"
    print_dns_diagnostics "$LAST_TUNNEL_HOST"
    echo ""
    echo "local proxy /v1/models:"
    if curl -fsS --max-time 10 http://127.0.0.1:9000/v1/models >/dev/null 2>&1; then
        echo "ok"
    else
        echo "failed"
    fi
    echo ""
    echo "current: $(cat "$CURRENT_FILE" 2>/dev/null || echo 'none')"
    echo "pending: $(cat "$PENDING_FILE" 2>/dev/null || echo 'none')"
    echo "stale: $(cat "$STALE_FILE" 2>/dev/null || echo 'none')"
}

main() {
    verify_try_one_tunnel_dns_order

    log_info "Preparing DeepSeek Cursor Quick Tunnel at login..."

    log_info "Stopping URL updater timer/service while preparing..."
    systemctl --user stop update-cursor-deepseek-url.timer || true
    systemctl --user stop update-cursor-deepseek-url.service || true
    systemctl --user reset-failed update-cursor-deepseek-url.service || true
    trap cleanup EXIT INT TERM

    log_info "Starting deepseek-cursor-proxy.service..."
    systemctl --user start deepseek-cursor-proxy.service

    local tunnel_result=0
    try_tunnel_attempts || tunnel_result=$?
    if [[ $tunnel_result -eq "$EXIT_ROUTER_DNS_STALE" ]]; then
        print_diagnostics
        if [[ -n "$LAST_TUNNEL_HOST" ]] && cloudflare_doh_resolves "$LAST_TUNNEL_HOST"; then
            log_error "Cloudflare DoH resolves $LAST_TUNNEL_HOST, but system resolver still returns NXDOMAIN/stale result."
            log_error "Router DNS may have negative-cached this hostname."
        fi
        log_error "Allowlist or clear DNS cache for *.trycloudflare.com on DNS gateway/router."
        exit 1
    fi
    if [[ $tunnel_result -ne 0 ]]; then
        print_diagnostics
        exit 1
    fi

    log_info "Running Cursor URL updater..."
    systemctl --user start update-cursor-deepseek-url.service || true

    local updater_result=0
    wait_for_updater_result || updater_result=$?
    if [[ $updater_result -ne 0 ]]; then
        if [[ $updater_result -eq "$EXIT_TEMPFAIL" ]]; then
            log_warn "Boot preparation paused: pending URL waiting for Cursor to close."
            exit "$EXIT_TEMPFAIL"
        fi
        print_diagnostics
        exit 1
    fi

    log_info "Boot preparation complete."
    exit 0
}

main "$@"
