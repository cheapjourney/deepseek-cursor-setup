#!/usr/bin/env bash
# update-cursor-deepseek-url.sh
# Reads the Cloudflare tunnel URL from cloudflared logs and updates
# Cursor's state.vscdb to point to the new tunnel URL.
set -euo pipefail

CACHE_DIR="${HOME}/.cache/deepseek-cursor-proxy"
CLOUDFLARED_LOG="${CACHE_DIR}/cloudflared.log"
CURSOR_DB="${HOME}/.config/Cursor/User/globalStorage/state.vscdb"
BACKUP_DIR="${HOME}/Backups/cursor-state-auto"
PENDING_BASE_URL_FILE="${CACHE_DIR}/pending-base-url.txt"
CURRENT_BASE_URL_FILE="${CACHE_DIR}/current-base-url.txt"
STALE_BASE_URL_FILE="${CACHE_DIR}/stale-base-url.txt"
ACTIVE_KEY="src.vs.platform.reactivestorage.browser.reactiveStorageServiceImpl.persistentStorage.applicationUser"
DRY_RUN=false
WAIT_MAX_SEC=120
WAIT_INTERVAL=3
EXIT_TEMPFAIL=75

log_info()  { echo "[INFO]  $*"; }
log_warn()  { echo "[WARN]  $*" >&2; }
log_error() { echo "[ERROR] $*" >&2; }
log_dry()   { echo "[DRY-RUN] $*"; }

if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
    log_info "DRY-RUN mode — no changes will be written."
fi

normalize_base_url() {
    local url="$1"
    url="${url%/}"
    if [[ "$url" != */v1 ]]; then
        url="${url}/v1"
    fi
    printf '%s' "$url"
}

escape_sql() {
    printf "%s" "$1" | sed "s/'/''/g"
}

cursor_is_running() {
    ps -eo pid=,args= | awk '/\/usr\/share\/cursor\/cursor([[:space:]]|$)/ { found=1 } END { exit found ? 0 : 1 }'
}

save_pending_base_url() {
    local base_url="$1"
    mkdir -p "$CACHE_DIR"
    printf '%s\n' "$base_url" > "$PENDING_BASE_URL_FILE"
}

save_current_base_url() {
    local base_url="$1"
    mkdir -p "$CACHE_DIR"
    printf '%s\n' "$base_url" > "$CURRENT_BASE_URL_FILE"
}

clear_pending_base_url() {
    if [[ -f "$PENDING_BASE_URL_FILE" ]]; then
        rm -f "$PENDING_BASE_URL_FILE"
    fi
}

send_desktop_notification() {
    if [[ "${DEEPSEEK_CURSOR_NOTIFY:-0}" != "1" ]]; then
        return 0
    fi

    command -v notify-send >/dev/null 2>&1 || return 0
    notify-send "DeepSeek Cursor Proxy" "$*" >/dev/null 2>&1 || true
}

base_url_is_reachable() {
    local base_url="$1"
    local root_url="${base_url%/v1}"
    root_url="${root_url%/}"
    curl -fsS --max-time 10 "${root_url}/healthz" >/dev/null 2>&1 \
        || curl -fsS --max-time 10 "${base_url}/healthz" >/dev/null 2>&1 \
        || return 1
    curl -fsS --max-time 10 "${base_url}/models" >/dev/null 2>&1 \
        || curl -fsS --max-time 10 "${root_url}/v1/models" >/dev/null 2>&1
}

invalidate_stale_current_base_url() {
    local current_url=""
    if [[ ! -f "$CURRENT_BASE_URL_FILE" ]]; then
        return 0
    fi

    current_url="$(tr -d '\r\n' < "$CURRENT_BASE_URL_FILE")"
    if [[ -z "$current_url" ]]; then
        rm -f "$CURRENT_BASE_URL_FILE"
        return 0
    fi

    if base_url_is_reachable "$current_url"; then
        return 0
    fi

    if [[ "$DRY_RUN" == true ]]; then
        log_dry "Would move stale current-base-url to stale-base-url.txt: $current_url"
        return 0
    fi

    printf '%s\n' "$current_url" > "$STALE_BASE_URL_FILE"
    rm -f "$CURRENT_BASE_URL_FILE"
    log_warn "Existing current-base-url is stale; moved to stale-base-url.txt"
}

wait_for_cloudflared_log() {
    local wait_max_sec=60
    local wait_interval=2
    local elapsed=0

    if [[ -f "$CLOUDFLARED_LOG" ]]; then
        return 0
    fi

    log_info "Cloudflared log not yet available, waiting up to ${wait_max_sec}s..."
    while [[ $elapsed -lt $wait_max_sec ]]; do
        sleep "$wait_interval"
        elapsed=$((elapsed + wait_interval))
        if [[ -f "$CLOUDFLARED_LOG" ]]; then
            log_info "Cloudflared log appeared after ${elapsed}s."
            return 0
        fi
    done

    log_error "Cloudflared log not found after ${wait_max_sec}s: $CLOUDFLARED_LOG"
    return 1
}

# Prefer the newest reachable URL from cloudflared logs (never a stale entry).
find_reachable_root_url() {
    local -a candidates=()
    mapfile -t candidates < <(
        grep -oE 'https://[-a-z0-9]+\.trycloudflare\.com' "$CLOUDFLARED_LOG" 2>/dev/null \
            | tac \
            | awk '!seen[$0]++'
    )

    local candidate=""
    for candidate in "${candidates[@]}"; do
        candidate="${candidate%/}"
        if curl -fsS --max-time 10 "${candidate}/healthz" >/dev/null 2>&1 \
           && curl -fsS --max-time 10 "${candidate}/v1/models" >/dev/null 2>&1; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    return 1
}

if ! wait_for_cloudflared_log; then
    exit 1
fi

if [[ ! -f "$CURSOR_DB" ]]; then
    log_error "Cursor database not found: $CURSOR_DB"
    exit 1
fi

log_info "Waiting for tunnel URL to become reachable (max ${WAIT_MAX_SEC}s, every ${WAIT_INTERVAL}s)..."

NEW_ROOT_URL=""
ELAPSED=0
while [[ $ELAPSED -lt $WAIT_MAX_SEC ]]; do
    if NEW_ROOT_URL="$(find_reachable_root_url)"; then
        log_info "Reachable tunnel URL found: $NEW_ROOT_URL"
        break
    fi
    sleep "$WAIT_INTERVAL"
    ELAPSED=$((ELAPSED + WAIT_INTERVAL))
done

if [[ -z "$NEW_ROOT_URL" ]]; then
    log_error "No reachable tunnel URL found within ${WAIT_MAX_SEC}s."
    log_error "Neither /healthz nor /v1/models was reachable. No DB change."
    invalidate_stale_current_base_url
    exit 1
fi

NEW_BASE_URL="$(normalize_base_url "$NEW_ROOT_URL")"

log_info "Reading current Cursor config key from ItemTable..."
CURRENT_VALUE="$(sqlite3 "$CURSOR_DB" "SELECT value FROM ItemTable WHERE key='$(escape_sql "$ACTIVE_KEY")';" 2>/dev/null || true)"
if [[ -z "$CURRENT_VALUE" ]]; then
    log_error "Active key not found: $ACTIVE_KEY"
    exit 1
fi

OLD_BASE_URL_RAW="$(printf "%s" "$CURRENT_VALUE" | rg -o 'https://[-a-z0-9]+\.trycloudflare\.com(/v1)?' -N -m 1 || true)"
if [[ -z "$OLD_BASE_URL_RAW" ]]; then
    log_warn "No trycloudflare URL found in active key. No change."
    exit 0
fi

OLD_BASE_URL="$(normalize_base_url "$OLD_BASE_URL_RAW")"

log_info "Current openAIBaseUrl:  $OLD_BASE_URL"
log_info "New openAIBaseUrl:      $NEW_BASE_URL"

if [[ "$OLD_BASE_URL" == "$NEW_BASE_URL" ]]; then
    log_info "openAIBaseUrl is already up to date. No change needed."
    if [[ "$DRY_RUN" != true ]]; then
        save_current_base_url "$NEW_BASE_URL"
        clear_pending_base_url
    fi
    exit 0
fi

log_info "Checking if Cursor is running..."
if cursor_is_running; then
    if [[ "$DRY_RUN" == true ]]; then
        log_dry "Cursor is running; would save pending URL and exit ${EXIT_TEMPFAIL}."
        log_dry "Pending URL: $NEW_BASE_URL"
        exit 0
    fi

    save_pending_base_url "$NEW_BASE_URL"
    log_warn "Cursor is running. Saved pending tunnel URL to: $PENDING_BASE_URL_FILE"
    log_warn "Close Cursor so the updater can patch state.vscdb; the timer will retry automatically."
    send_desktop_notification "Close Cursor to apply the new tunnel URL: ${NEW_BASE_URL}"
    exit "$EXIT_TEMPFAIL"
fi
log_info "Cursor is not running."

if [[ "$DRY_RUN" == true ]]; then
    log_dry "Would patch key: $ACTIVE_KEY"
    log_dry "From: $OLD_BASE_URL"
    log_dry "To:   $NEW_BASE_URL"
    log_dry "No changes written."
    exit 0
fi

mkdir -p "$BACKUP_DIR"
BACKUP_FILE="${BACKUP_DIR}/state.vscdb.$(date +%Y%m%d-%H%M%S).bak"
cp "$CURSOR_DB" "$BACKUP_FILE"
log_info "Backup created: $BACKUP_FILE"

python3 - "$CURSOR_DB" "$NEW_BASE_URL" "$ACTIVE_KEY" "$BACKUP_FILE" <<'PYEOF'
import sys, re, sqlite3

cursor_db = sys.argv[1]
new_base_url = sys.argv[2]
active_key = sys.argv[3]
backup_file = sys.argv[4]

con = sqlite3.connect(cursor_db)
try:
    cur = con.execute("SELECT value FROM ItemTable WHERE key=?", (active_key,))
    row = cur.fetchone()
    if row is None:
        print("[ERROR] Key not found: " + active_key, file=sys.stderr)
        sys.exit(1)

    current_value = row[0]
    new_value, count = re.subn(
        r'https://[-a-z0-9]+\.trycloudflare\.com(?:/v1)?',
        new_base_url,
        current_value,
        count=1,
    )

    if count == 0 or new_value == current_value:
        print("[ERROR] No trycloudflare URL replaced in active key.", file=sys.stderr)
        sys.exit(1)

    con.execute("UPDATE ItemTable SET value=? WHERE key=?", (new_value, active_key))
    con.commit()
    print("[INFO]  Running SQLite WAL checkpoint...")
    con.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    print("[INFO]  Update complete.")
    print("[INFO]  Updated: ItemTable/" + active_key)
    print("[INFO]  New openAIBaseUrl: " + new_base_url)
    print("[INFO]  Backup: " + backup_file)
finally:
    con.close()
PYEOF

save_current_base_url "$NEW_BASE_URL"
clear_pending_base_url
log_info "Applied tunnel URL saved to: $CURRENT_BASE_URL_FILE"
