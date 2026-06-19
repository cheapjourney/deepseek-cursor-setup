#!/usr/bin/env bash
# smoke.sh — Lightweight offline smoke tests for deepseek-cursor-setup
# Does not require network access.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

PASS=0
FAIL=0
ERRORS=()

assert() {
    local description="$1"
    shift
    if "$@"; then
        echo "[PASS] $description"
        PASS=$((PASS + 1))
        return 0
    else
        echo "[FAIL] $description"
        FAIL=$((FAIL + 1))
        ERRORS+=("$description")
        return 1
    fi
}

echo "======================================"
echo " Smoke tests — deepseek-cursor-setup"
echo "======================================"
echo ""

# ── Shell syntax checks ──────────────────────────────────────────────
echo "--- Shell syntax checks ---"

for script in \
    "$REPO_DIR/install.sh" \
    "$REPO_DIR/uninstall.sh" \
    "$REPO_DIR/bootstrap.sh" \
    "$REPO_DIR/bin/update-cursor-deepseek-url.sh" \
    "$REPO_DIR/bin/deepseek-cursor-boot-prepare.sh"
do
    name="$(basename "$script")"
    assert "bash -n $name" bash -n "$script"
done

echo ""

# ── Content assertions ───────────────────────────────────────────────
echo "--- Content assertions ---"

# notify-send is guarded behind DEEPSEEK_CURSOR_NOTIFY env var
NOTIFY_FILE="$REPO_DIR/bin/update-cursor-deepseek-url.sh"
assert "notify-send guarded behind DEEPSEEK_CURSOR_NOTIFY" \
    sh -c "grep -q 'DEEPSEEK_CURSOR_NOTIFY' '$NOTIFY_FILE' && grep -q 'notify-send' '$NOTIFY_FILE'"

assert "send_desktop_notification returns early when DEEPSEEK_CURSOR_NOTIFY != 1" \
    sh -c "grep -A3 'send_desktop_notification()' '$NOTIFY_FILE' | grep -q 'DEEPSEEK_CURSOR_NOTIFY'"

# cloudflared service uses --protocol http2
CLOUDFLARED_SERVICE="$REPO_DIR/systemd/cloudflared-deepseek-quick.service"
assert "cloudflared-deepseek-quick.service contains --protocol http2" \
    grep -q -- '--protocol http2' "$CLOUDFLARED_SERVICE"

# boot-prepare service accepts exit code 75
BOOT_PREPARE_SERVICE="$REPO_DIR/systemd/deepseek-cursor-boot-prepare.service"
assert "deepseek-cursor-boot-prepare.service contains SuccessExitStatus=75" \
    grep -q 'SuccessExitStatus=75' "$BOOT_PREPARE_SERVICE"

# URL updater service also accepts exit code 75
UPDATER_SERVICE="$REPO_DIR/systemd/update-cursor-deepseek-url.service"
assert "update-cursor-deepseek-url.service contains SuccessExitStatus=75" \
    grep -q 'SuccessExitStatus=75' "$UPDATER_SERVICE"

# DNS_DOH_GATE_PASSED runtime guard exists in boot-prepare
BOOT_SCRIPT="$REPO_DIR/bin/deepseek-cursor-boot-prepare.sh"
assert "host_resolves() guards on DNS_DOH_GATE_PASSED" \
    grep -q 'DNS_DOH_GATE_PASSED' "$BOOT_SCRIPT"

assert "wait_for_cloudflare_doh sets DNS_DOH_GATE_PASSED=true" \
    grep -q 'DNS_DOH_GATE_PASSED=true' "$BOOT_SCRIPT"

# Verify source-code self-parsing has been replaced with runtime guard
assert "no sed-based self-parsing in boot-prepare (runtime guard only)" \
    sh -c "! grep -q \"sed -n '/\\^try_one_tunnel\" '$BOOT_SCRIPT'"

# systemd services reference the correct binaries
assert "cloudflared service references cloudflared binary" \
    grep -q 'cloudflared' "$CLOUDFLARED_SERVICE"

assert "proxy service references deepseek-cursor-proxy" \
    grep -q 'deepseek-cursor-proxy' "$REPO_DIR/systemd/deepseek-cursor-proxy.service"

# install.sh checks dependencies
assert "install.sh checks for required commands" \
    sh -c "grep -q 'for cmd in' '$REPO_DIR/install.sh' && grep -q 'missing' '$REPO_DIR/install.sh'"

# LICENSE exists
assert "LICENSE file exists" test -f "$REPO_DIR/LICENSE"

# CI workflow exists
assert ".github/workflows/ci.yml exists" test -f "$REPO_DIR/.github/workflows/ci.yml"

echo ""
echo "======================================"
echo " Results: $PASS passed, $FAIL failed"
echo "======================================"

if [[ $FAIL -gt 0 ]]; then
    echo ""
    echo "Failed tests:"
    for err in "${ERRORS[@]}"; do
        echo "  - $err"
    done
    exit 1
fi

exit 0
