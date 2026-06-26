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
    "$REPO_DIR/bin/deepseek-cursor-rearm-url-timer.sh" \
    "$REPO_DIR/bin/deepseek-cursor-boot-prepare.sh" \
    "$REPO_DIR/bin/deepseek-cursor-pending-watcher.sh" \
    "$REPO_DIR/bin/deepseek-cursor-resume-recover.sh"
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

# Fix A: "already up to date" path must check cursor_is_running before clearing pending
UPDATER_SCRIPT="$REPO_DIR/bin/update-cursor-deepseek-url.sh"
assert "Fix A: 'already up to date' path checks cursor_is_running before clearing pending" \
    sh -c "grep -A12 'OLD_BASE_URL.*==.*NEW_BASE_URL' '$UPDATER_SCRIPT' | grep -q 'cursor_is_running'"

assert "Fix A: 'already up to date' path exits with EXIT_TEMPFAIL when Cursor is running" \
    sh -c "grep -A12 'OLD_BASE_URL.*==.*NEW_BASE_URL' '$UPDATER_SCRIPT' | grep -q 'EXIT_TEMPFAIL'"

# Fix B: pending-watcher systemd units exist
WATCHER_SERVICE="$REPO_DIR/systemd/deepseek-cursor-pending-watcher.service"
WATCHER_PATH="$REPO_DIR/systemd/deepseek-cursor-pending-watcher.path"
assert "Fix B: deepseek-cursor-pending-watcher.service exists" test -f "$WATCHER_SERVICE"
assert "Fix B: deepseek-cursor-pending-watcher.path exists" test -f "$WATCHER_PATH"

assert "Fix B: pending-watcher.service contains SuccessExitStatus=75" \
    grep -q 'SuccessExitStatus=75' "$WATCHER_SERVICE"

assert "Fix B: pending-watcher.path watches pending-base-url.txt" \
    grep -q 'pending-base-url.txt' "$WATCHER_PATH"

# Fix B: watcher script has flock lock protection
WATCHER_SCRIPT="$REPO_DIR/bin/deepseek-cursor-pending-watcher.sh"
assert "Fix B: pending-watcher script uses flock for mutual exclusion" \
    grep -q 'flock' "$WATCHER_SCRIPT"

assert "Fix B: pending-watcher script has 8h timeout" \
    grep -q 'MAX_WAIT_SEC=28800' "$WATCHER_SCRIPT"

assert "Fix B: pending-watcher script polls cursor_is_running" \
    grep -q 'cursor_is_running' "$WATCHER_SCRIPT"

# Fix B: install.sh deploys watcher units with enable --now
assert "Fix B: install.sh uses enable --now for pending-watcher.path" \
    grep -q 'enable --now.*deepseek-cursor-pending-watcher.path' "$REPO_DIR/install.sh"

assert "Fix B: install.sh installs pending-watcher binary" \
    grep -q 'deepseek-cursor-pending-watcher.sh' "$REPO_DIR/install.sh"

# ensure timer is enabled and re-armed on install (not only enable --now)
assert "install.sh enables update-cursor-deepseek-url.timer" \
    grep -q 'enable update-cursor-deepseek-url.timer' "$REPO_DIR/install.sh"

assert "install.sh re-arms URL updater timer via deepseek-cursor-rearm-url-timer" \
    grep -q 'deepseek-cursor-rearm-url-timer' "$REPO_DIR/install.sh"

assert "update-cursor-deepseek-url.timer has OnCalendar=minutely fallback" \
    grep -q 'OnCalendar=minutely' "$REPO_DIR/systemd/update-cursor-deepseek-url.timer"

assert "deepseek-cursor-rearm-url-timer.sh exists" \
    test -f "$REPO_DIR/bin/deepseek-cursor-rearm-url-timer.sh"

assert "boot-prepare cleanup uses rearm-url-timer helper" \
    grep -q 'deepseek-cursor-rearm-url-timer' "$REPO_DIR/bin/deepseek-cursor-boot-prepare.sh"

assert "pending-watcher re-arms URL updater timer after patch" \
    grep -q 'rearm_url_timer' "$WATCHER_SCRIPT"

# Fix B: uninstall.sh removes watcher units
assert "Fix B: uninstall.sh stops pending-watcher.path" \
    grep -q 'deepseek-cursor-pending-watcher.path' "$REPO_DIR/uninstall.sh"

assert "Fix B: uninstall.sh removes pending-watcher binary" \
    grep -q 'deepseek-cursor-pending-watcher' "$REPO_DIR/uninstall.sh"

# Resume recovery after suspend
RESUME_SCRIPT="$REPO_DIR/bin/deepseek-cursor-resume-recover.sh"
RESUME_SERVICE="$REPO_DIR/systemd/deepseek-cursor-resume-recover.service"
RESUME_SLEEP_HOOK="$REPO_DIR/systemd-sleep/deepseek-cursor-resume"

assert "Resume: deepseek-cursor-resume-recover.sh exists" test -f "$RESUME_SCRIPT"
assert "Resume: deepseek-cursor-resume-recover.service exists" test -f "$RESUME_SERVICE"
assert "Resume: systemd-sleep hook template exists" test -f "$RESUME_SLEEP_HOOK"

assert "Resume: service contains SuccessExitStatus=75" \
    grep -q 'SuccessExitStatus=75' "$RESUME_SERVICE"

assert "Resume: script uses flock for mutual exclusion" \
    grep -q 'flock' "$RESUME_SCRIPT"

assert "Resume: script restarts cloudflared-deepseek-quick.service" \
    grep -q 'restart cloudflared-deepseek-quick.service' "$RESUME_SCRIPT"

assert "Resume: script starts deepseek-cursor-boot-prepare.service" \
    grep -q 'start deepseek-cursor-boot-prepare.service' "$RESUME_SCRIPT"

assert "Resume: install.sh installs resume-recover binary" \
    grep -q 'deepseek-cursor-resume-recover.sh' "$REPO_DIR/install.sh"

assert "Resume: install.sh installs system-sleep hook" \
    grep -q 'system-sleep/deepseek-cursor-resume' "$REPO_DIR/install.sh"

assert "Resume: install.sh uses sudo for system-sleep hook" \
    sh -c "grep -q 'sudo tee' '$REPO_DIR/install.sh' && grep -q 'system-sleep/deepseek-cursor-resume' '$REPO_DIR/install.sh'"

assert "Resume: uninstall.sh removes system-sleep hook" \
    grep -q 'system-sleep/deepseek-cursor-resume' "$REPO_DIR/uninstall.sh"

assert "Resume: sleep hook starts resume-recover on post" \
    grep -q 'deepseek-cursor-resume-recover.service' "$RESUME_SLEEP_HOOK"

assert "Resume: sleep hook exits 0 on pre" \
    sh -c "grep -A2 'pre)' '$RESUME_SLEEP_HOOK' | grep -q 'exit 0'"

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
