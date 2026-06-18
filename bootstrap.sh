#!/usr/bin/env bash
# bootstrap.sh — One-command setup for DeepSeek Cursor Proxy
# Clones or updates this repo and runs install.sh.
set -euo pipefail

REPO_URL="https://github.com/cheapjourney/deepseek-cursor-setup.git"
SETUP_DIR="$HOME/deepseek-cursor-setup"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m'

info()  { echo -e "${BLUE}[INFO]${NC}  $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*"; }
err()   { echo -e "${RED}[ERROR]${NC} $*"; }
ok()    { echo -e "${GREEN}[OK]${NC}   $*"; }

echo ""
echo "======================================"
echo " DeepSeek Cursor Proxy — Bootstrap"
echo "======================================"
echo ""

# ── Clone or update the setup repo ──────────────────────────────────
if [[ -d "$SETUP_DIR/.git" ]]; then
    info "Setup repo already exists at $SETUP_DIR"
    info "Updating with git pull --ff-only..."
    git -C "$SETUP_DIR" pull --ff-only && ok "Updated successfully" || {
        warn "git pull failed. Continuing with existing copy."
    }
elif [[ -d "$SETUP_DIR" ]]; then
    err "$SETUP_DIR exists but is not a git repository."
    err "Cannot bootstrap. Please move or remove it first:"
    err "  mv $SETUP_DIR ${SETUP_DIR}.bak"
    err "Then re-run this script."
    exit 1
else
    info "Cloning setup repo into $SETUP_DIR..."
    git clone "$REPO_URL" "$SETUP_DIR" && ok "Cloned successfully" || {
        err "Clone failed. Check your internet connection and the repo URL:"
        err "  $REPO_URL"
        exit 1
    }
fi

# ── Run install.sh ──────────────────────────────────────────────────
echo ""
info "Making install.sh executable..."
chmod +x "$SETUP_DIR/install.sh"

info "Running install.sh..."
cd "$SETUP_DIR"
exec ./install.sh
