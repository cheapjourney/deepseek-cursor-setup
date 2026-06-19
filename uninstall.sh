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
stop_service "deepseek-cursor-boot-prepare.service"
stop_service "deepseek-cursor-proxy.service"
stop_service "cloudflared-deepseek-quick.service"
stop_service "update-cursor-deepseek-url.timer"
stop_service "update-cursor-deepseek-url.service"

# ── Disable services ────────────────────────────────────────────────
echo ""
log "Disabling services..."
disable_service "deepseek-cursor-boot-prepare.service"
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
    "deepseek-cursor-boot-prepare.service"
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

# ── Remove helper scripts ─────────────────────────────────────────────
echo ""
for bin_path in \
    "$HOME/.local/bin/update-cursor-deepseek-url" \
    "$HOME/.local/bin/deepseek-cursor-boot-prepare" \
    "$HOME/.local/bin/cursor-deepseek"
do
    if [[ -f "$bin_path" ]]; then
        rm -f "$bin_path"
        log "Removed: $bin_path"
    else
        log "Not found (already removed): $bin_path"
    fi
done

# ── Remove legacy launcher desktop files ──────────────────────────────
echo ""
APPLICATIONS_DIR="$HOME/.local/share/applications"
AUTOSTART_DIR="$HOME/.config/autostart"

remove_desktop_if_wrapper() {
    local desktop="$1"
    [[ -f "$desktop" ]] || return 0
    if grep -q 'cursor-deepseek' "$desktop" 2>/dev/null; then
        rm -f "$desktop"
        log "Removed legacy desktop override: $desktop"
    fi
}

for legacy in \
    "$APPLICATIONS_DIR/cursor-deepseek.desktop" \
    "$AUTOSTART_DIR/cursor-deepseek.desktop"
do
    if [[ -f "$legacy" ]]; then
        rm -f "$legacy"
        log "Removed legacy launcher: $legacy"
    fi
done

shopt -s nullglob
for desktop in "$APPLICATIONS_DIR"/*.desktop; do
    remove_desktop_if_wrapper "$desktop"
done
for desktop in "$AUTOSTART_DIR"/*.desktop; do
    remove_desktop_if_wrapper "$desktop"
done
shopt -u nullglob

if command -v update-desktop-database &>/dev/null && [[ -d "$APPLICATIONS_DIR" ]]; then
    update-desktop-database "$APPLICATIONS_DIR" 2>/dev/null || true
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
echo "scripts have been removed."
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
echo "Disabled Cursor autostart entries (if any) are in:"
echo "  ~/.config/autostart-disabled/"
echo ""
