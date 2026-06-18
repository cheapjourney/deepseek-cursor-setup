#!/usr/bin/env bash
# uninstall.sh — Remove DeepSeek Cursor Proxy services and helpers
# Idempotent: safe to run multiple times.
set -euo pipefail

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()   { echo -e "${GREEN}[✓]${NC} $*"; }
warn()  { echo -e "${YELLOW}[!]${NC} $*"; }
err()   { echo -e "${RED}[✗]${NC} $*"; }

echo ""
echo "======================================"
echo " DeepSeek Cursor Proxy — Uninstall"
echo "======================================"
echo ""

# ── Stop services ───────────────────────────────────────────────────
stop_service() {
    local svc="$1"
    if systemctl --user --quiet is-active "$svc" 2>/dev/null; then
        systemctl --user stop "$svc" && log "Stopped $svc" || warn "Failed to stop $svc"
    else
        log "$svc is not running (already stopped)"
    fi
}

disable_service() {
    local svc="$1"
    if systemctl --user --quiet is-enabled "$svc" 2>/dev/null; then
        systemctl --user disable "$svc" && log "Disabled $svc" || warn "Failed to disable $svc"
    else
        log "$svc is not enabled (already disabled)"
    fi
}

log "Stopping services..."
stop_service "deepseek-cursor-proxy.service"
stop_service "cloudflared-deepseek-quick.service"
stop_service "update-cursor-deepseek-url.timer"
stop_service "update-cursor-deepseek-url.service"

# ── Disable services ────────────────────────────────────────────────
echo ""
log "Disabling services..."
disable_service "deepseek-cursor-proxy.service"
disable_service "cloudflared-deepseek-quick.service"
disable_service "update-cursor-deepseek-url.timer"
disable_service "update-cursor-deepseek-url.service"

# ── Remove systemd unit files ───────────────────────────────────────
echo ""
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
UNITS=(
    "deepseek-cursor-proxy.service"
    "cloudflared-deepseek-quick.service"
    "update-cursor-deepseek-url.service"
    "update-cursor-deepseek-url.timer"
)

log "Removing systemd unit files from $SYSTEMD_USER_DIR..."
removed_any=false
for unit in "${UNITS[@]}"; do
    unit_path="$SYSTEMD_USER_DIR/$unit"
    if [[ -f "$unit_path" ]]; then
        rm -f "$unit_path"
        log "Removed: $unit"
        removed_any=true
    else
        log "Not found (already removed): $unit"
    fi
done

if ! $removed_any; then
    log "No unit files to remove"
fi

# ── Remove helper script ────────────────────────────────────────────
echo ""
UPDATE_BIN="$HOME/.local/bin/update-cursor-deepseek-url"
if [[ -f "$UPDATE_BIN" ]]; then
    rm -f "$UPDATE_BIN"
    log "Removed: $UPDATE_BIN"
else
    log "Helper script not found (already removed): $UPDATE_BIN"
fi

# ── Reload systemd ──────────────────────────────────────────────────
echo ""
systemctl --user daemon-reload
log "systemd daemon-reload completed"

# ── Optional cleanup ────────────────────────────────────────────────
echo ""
echo "======================================"
echo " Uninstall complete!"
echo "======================================"
echo ""
echo "Services stopped and disabled. Systemd unit files and helper"
echo "script have been removed."
echo ""
echo "Optional — remove data/config/cache directories:"
echo ""
echo "  # DeepSeek Cursor Proxy (Python project)"
echo "  rm -rf ~/tools/deepseek-cursor-proxy"
echo ""
echo "  # Proxy configuration"
echo "  rm -rf ~/.deepseek-cursor-proxy"
echo ""
echo "  # Cache (logs, tunnel URL files)"
echo "  rm -rf ~/.cache/deepseek-cursor-proxy"
echo ""
echo "  # Cursor state backups"
echo "  rm -rf ~/Backups/cursor-state-auto"
echo ""
echo "These directories contain user data, configs, and backups."
echo "They are NOT automatically removed."
echo ""
