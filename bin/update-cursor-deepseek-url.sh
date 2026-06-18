#!/usr/bin/env bash
# update-cursor-deepseek-url.sh
# Reads the Cloudflare tunnel URL from cloudflared logs and updates
# Cursor's state.vscdb to point to the new tunnel URL.
set -euo pipefail

CLOUDFLARED_LOG="${HOME}/.cache/deepseek-cursor-proxy/cloudflared.log"
CURSOR_DB="${HOME}/.config/Cursor/User/globalStorage/state.vscdb"
BACKUP_DIR="${HOME}/Backups/cursor-state-auto"
ACTIVE_KEY="src.vs.platform.reactivestorage.browser.reactiveStorageServiceImpl.persistentStorage.applicationUser"
DRY_RUN=false
WAIT_MAX_SEC=120
WAIT_INTERVAL=3

log_info()  { echo "[INFO]  $*"; }
log_warn()  { echo "[WARN]  $*" >&2; }
log_error() { echo "[ERROR] $*" >&2; }
log_dry()   { echo "[DRY-RUN] $*"; }

if [[ "${1:-}" == "--dry-run" ]]; then
    DRY_RUN=true
    log_info "DRY-RUN mode — no changes will be written."
fi

extract_url() {
    grep -oE 'https://[-a-z0-9]+\.trycloudflare\.com' "$CLOUDFLARED_LOG" 2>/dev/null | tail -1 || true
}

escape_sql() {
    printf "%s" "$1" | sed "s/'/''/g"
}

if [[ ! -f "$CLOUDFLARED_LOG" ]]; then
    log_error "Cloudflared log not found: $CLOUDFLARED_LOG"
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
    CANDIDATE_URL="$(extract_url)"
    if [[ -n "$CANDIDATE_URL" ]]; then
        CANDIDATE_URL="${CANDIDATE_URL%/}"
        if curl -fsS --max-time 10 "${CANDIDATE_URL}/healthz" >/dev/null 2>&1 \
           && curl -fsS --max-time 10 "${CANDIDATE_URL}/v1/models" >/dev/null 2>&1; then
            NEW_ROOT_URL="$CANDIDATE_URL"
            log_info "Reachable tunnel URL found: $NEW_ROOT_URL"
            break
        fi
    fi
    sleep "$WAIT_INTERVAL"
    ELAPSED=$((ELAPSED + WAIT_INTERVAL))
done

if [[ -z "$NEW_ROOT_URL" ]]; then
    log_error "No reachable tunnel URL found within ${WAIT_MAX_SEC}s."
    log_error "Neither /healthz nor /v1/models was reachable. No DB change."
    exit 1
fi

log_info "Checking if Cursor is running..."
if ps -eo pid=,args= | awk '/\/usr\/share\/cursor\/cursor([[:space:]]|$)/ { found=1 } END { exit found ? 0 : 1 }'; then
    log_error "Cursor is running. Please close Cursor or retry later."
    exit 2
fi
log_info "Cursor is not running."

log_info "Reading current Cursor config key from ItemTable..."
CURRENT_VALUE="$(sqlite3 "$CURSOR_DB" "SELECT value FROM ItemTable WHERE key='$(escape_sql "$ACTIVE_KEY")';" 2>/dev/null || true)"
if [[ -z "$CURRENT_VALUE" ]]; then
    log_error "Active key not found: $ACTIVE_KEY"
    exit 1
fi

OLD_ROOT_URL="$(printf "%s" "$CURRENT_VALUE" | rg -o 'https://[-a-z0-9]+\.trycloudflare\.com' -N -m 1 || true)"
if [[ -z "$OLD_ROOT_URL" ]]; then
    log_warn "No trycloudflare URL found in active key. No change."
    exit 0
fi

log_info "Current openAIBaseUrl:  $OLD_ROOT_URL"
log_info "New openAIBaseUrl:      $NEW_ROOT_URL"

if [[ "$OLD_ROOT_URL" == "$NEW_ROOT_URL" ]]; then
    log_info "openAIBaseUrl is already up to date. No change needed."
    exit 0
fi

if $DRY_RUN; then
    log_dry "Would patch key: $ACTIVE_KEY"
    log_dry "From: $OLD_ROOT_URL"
    log_dry "To:   $NEW_ROOT_URL"
    log_dry "No changes written."
    exit 0
fi

mkdir -p "$BACKUP_DIR"
BACKUP_FILE="${BACKUP_DIR}/state.vscdb.$(date +%Y%m%d-%H%M%S).bak"
cp "$CURSOR_DB" "$BACKUP_FILE"
log_info "Backup created: $BACKUP_FILE"

python3 - "$CURSOR_DB" "$NEW_ROOT_URL" "$ACTIVE_KEY" "$OLD_ROOT_URL" "$BACKUP_FILE" <<'PYEOF'
import sys, re, sqlite3

cursor_db = sys.argv[1]
new_root_url = sys.argv[2]
active_key = sys.argv[3]
old_root_url = sys.argv[4]
backup_file = sys.argv[5]

con = sqlite3.connect(cursor_db)
try:
    cur = con.execute("SELECT value FROM ItemTable WHERE key=?", (active_key,))
    row = cur.fetchone()
    if row is None:
        print("[ERROR] Key not found: " + active_key, file=sys.stderr)
        sys.exit(1)

    current_value = row[0]
    escaped_old = re.escape(old_root_url)
    new_value = re.sub(escaped_old, new_root_url, current_value)

    if new_value == current_value:
        print("[WARN]  No replacement match found in active key. No change.")
        sys.exit(0)

    con.execute("UPDATE ItemTable SET value=? WHERE key=?", (new_value, active_key))
    con.commit()
    print("[INFO]  Running SQLite WAL checkpoint...")
    con.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    print("[INFO]  Update complete.")
    print("[INFO]  Updated: ItemTable/" + active_key)
    print("[INFO]  New openAIBaseUrl: " + new_root_url)
    print("[INFO]  Backup: " + backup_file)
finally:
    con.close()
PYEOF
