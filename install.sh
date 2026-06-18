#!/usr/bin/env bash
# install.sh — DeepSeek Cursor Proxy Plug-and-Play Setup
# Run this after a fresh Ubuntu install to restore the full DeepSeek + Cursor setup.
set -euo pipefail

SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

REPO_URL="https://github.com/yxlao/deepseek-cursor-proxy.git"
CLOUDFLARED_URL="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*"; }

# ── Check dependencies ──────────────────────────────────────────────
echo ""
echo "======================================"
echo " DeepSeek Cursor Proxy — Setup"
echo "======================================"
echo ""

missing=()
for cmd in git curl python3 sqlite3 rg; do
    if ! command -v "$cmd" &>/dev/null; then
        missing+=("$cmd")
    fi
done

if [[ ${#missing[@]} -gt 0 ]]; then
    err "Missing dependencies: ${missing[*]}"
    echo "Install with: sudo apt install -y ${missing[*]} uv"
    echo "(uv is also required — install from https://astral.sh if not present)"
    exit 1
fi
log "Dependencies OK"

if ! command -v uv &>/dev/null; then
    warn "uv not found. Installing..."
    curl -LsSf https://astral.sh/uv/install.sh | sh
    export PATH="$HOME/.local/bin:$PATH"
fi
log "uv: $(command -v uv)"

# ── Clone / update deepseek-cursor-proxy ────────────────────────────
PROXY_DIR="$HOME/tools/deepseek-cursor-proxy"
if [[ -d "$PROXY_DIR/.git" ]]; then
    log "deepseek-cursor-proxy already exists, updating..."
    git -C "$PROXY_DIR" pull --ff-only && log "Updated successfully" || warn "git pull failed, continuing with existing copy"
elif [[ -d "$PROXY_DIR" ]]; then
    warn "$PROXY_DIR exists but is NOT a git repository."
    warn "Skipping clone to avoid overwriting your data."
    warn "If you want a fresh clone, remove this directory first:"
    warn "  rm -rf $PROXY_DIR"
else
    log "Cloning deepseek-cursor-proxy..."
    mkdir -p "$(dirname "$PROXY_DIR")"
    git clone "$REPO_URL" "$PROXY_DIR"
fi

# ── Install Python dependencies ─────────────────────────────────────
log "Setting up Python virtual environment..."
cd "$PROXY_DIR"
uv sync

# ── Install cloudflared ─────────────────────────────────────────────
CLOUDFLARED_BIN="$HOME/.local/bin/cloudflared"
if [[ -x "$CLOUDFLARED_BIN" ]]; then
    log "cloudflared already installed: $CLOUDFLARED_BIN"
else
    log "Downloading cloudflared..."
    curl -L --progress-bar -o "$CLOUDFLARED_BIN" "$CLOUDFLARED_URL"
    chmod +x "$CLOUDFLARED_BIN"
    log "cloudflared installed to $CLOUDFLARED_BIN"
fi

# ── Install proxy config ────────────────────────────────────────────
CONFIG_DIR="$HOME/.deepseek-cursor-proxy"
mkdir -p "$CONFIG_DIR"

SCRIPT_DIR="$SETUP_DIR"
if [[ -f "$CONFIG_DIR/config.yaml" ]]; then
    warn "Config already exists at $CONFIG_DIR/config.yaml, skipping."
else
    cp "$SCRIPT_DIR/config/config.yaml" "$CONFIG_DIR/config.yaml"
    log "Config installed to $CONFIG_DIR/config.yaml"
fi

# ── Install systemd user services ───────────────────────────────────
SYSTEMD_DIR="$HOME/.config/systemd/user"
mkdir -p "$SYSTEMD_DIR"

log "Installing systemd services..."
cp "$SCRIPT_DIR/systemd/deepseek-cursor-proxy.service" "$SYSTEMD_DIR/"
cp "$SCRIPT_DIR/systemd/cloudflared-deepseek-quick.service" "$SYSTEMD_DIR/"
cp "$SCRIPT_DIR/systemd/update-cursor-deepseek-url.service" "$SYSTEMD_DIR/"
cp "$SCRIPT_DIR/systemd/update-cursor-deepseek-url.timer" "$SYSTEMD_DIR/"

systemctl --user daemon-reload
systemctl --user enable --now deepseek-cursor-proxy.service
systemctl --user enable --now cloudflared-deepseek-quick.service
systemctl --user enable --now update-cursor-deepseek-url.timer

log "Services installed and enabled"

# ── Install update script ───────────────────────────────────────────
UPDATE_BIN="$HOME/.local/bin/update-cursor-deepseek-url"
cp "$SCRIPT_DIR/bin/update-cursor-deepseek-url.sh" "$UPDATE_BIN"
chmod +x "$UPDATE_BIN"
log "Update script installed to $UPDATE_BIN"

# ── Done ────────────────────────────────────────────────────────────
echo ""
echo "======================================"
echo " Setup complete!"
echo "======================================"
echo ""
echo "Services running:"
systemctl --user is-active deepseek-cursor-proxy.service && echo "  ✅ deepseek-cursor-proxy (port 9000)" || echo "  ❌ deepseek-cursor-proxy"
systemctl --user is-active cloudflared-deepseek-quick.service && echo "  ✅ cloudflared tunnel" || echo "  ❌ cloudflared"
systemctl --user is-active update-cursor-deepseek-url.timer && echo "  ✅ cursor URL updater timer" || echo "  ❌ cursor URL updater"
echo ""
echo "Next: In Cursor, set the API key:"
echo "  → Use model: deepseek-v4-pro (thinking) or deepseek-v4-flash (fast)"
echo "  → API Key: your DeepSeek API key"
echo "  → Base URL: auto-applied to Cursor when it is closed, or check:"
echo "      cat ~/.cache/deepseek-cursor-proxy/current-base-url.txt"
echo "    If Cursor was open during reboot, close it and wait for:"
echo "      cat ~/.cache/deepseek-cursor-proxy/pending-base-url.txt"
echo ""
echo "Management:"
echo "  systemctl --user status deepseek-cursor-proxy"
echo "  journalctl --user -u deepseek-cursor-proxy -f"
