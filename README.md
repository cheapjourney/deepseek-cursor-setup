# DeepSeek Cursor Setup

One-command setup to use DeepSeek models (`deepseek-v4-pro`, `deepseek-v4-flash`) in [Cursor](https://cursor.com/) — with thinking mode, reasoning display, and a Cloudflare reverse tunnel so you can access the proxy from anywhere.

## What This Does

- Runs a **local proxy** (`deepseek-cursor-proxy`) on `127.0.0.1:9000` that forwards Cursor requests to the DeepSeek API and fixes `reasoning_content` for tool calls.
- Creates a **Cloudflare Quick Tunnel** that exposes the proxy with a public `*.trycloudflare.com` URL.
- Sets up a **URL updater timer** that detects the tunnel URL, patches Cursor's `state.vscdb` database, and retries automatically until the new URL is applied.
- Everything runs as **systemd user services** and survives reboots.

## Requirements

- **Linux** with systemd (Ubuntu 24.04+, Debian, Fedora, etc.)
- **DeepSeek API key** — configured in Cursor, never stored by this repo
- **Cursor** IDE installed (Snap or AppImage)
- Dependencies auto-installed: `git`, `curl`, `python3`, `sqlite3`, `ripgrep` (`rg`), `uv`

> On Ubuntu/Debian, `rg` is in the `ripgrep` package:
> ```bash
> sudo apt install -y git curl python3 sqlite3 ripgrep
> ```

## Quick Install

### Method 1: Bootstrap (Recommended)

One command to clone or update the setup repo and run the installer:

```bash
curl -fsSL https://raw.githubusercontent.com/cheapjourney/deepseek-cursor-setup/master/bootstrap.sh | bash
```

Or if you prefer to inspect the script first:

```bash
git clone https://github.com/cheapjourney/deepseek-cursor-setup.git ~/deepseek-cursor-setup
cd ~/deepseek-cursor-setup
chmod +x bootstrap.sh && ./bootstrap.sh
```

### Method 2: Direct Install

```bash
git clone https://github.com/cheapjourney/deepseek-cursor-setup.git
cd deepseek-cursor-setup
chmod +x install.sh
./install.sh
```

## Cursor Configuration

After installation, open Cursor and go to **Settings → Models**. Add a model override:

- **Model name**: `deepseek-v4-pro` (thinking mode) or `deepseek-v4-flash` (fast)
- **API Key**: Your DeepSeek API key (e.g. `sk-...`)
- **Base URL**: The Cloudflare tunnel URL with `/v1` appended

**Base URL format:**

```
https://<something>.trycloudflare.com/v1
```

The base URL is **not** `http://localhost:9000/v1` — Cursor must connect through the Cloudflare tunnel to work correctly.

### Finding Your Base URL

The URL is automatically updated by the timer after reboot. Tunnel URL state files:

| File | Meaning |
|------|---------|
| `current-base-url.txt` | Verified reachable tunnel URL (includes `/v1`). Only present after a successful reachability check. |
| `pending-base-url.txt` | New URL detected, but Cursor is running — DB update is waiting. Close Cursor and let the timer retry. |
| `stale-base-url.txt` | Previous URL was invalidated (cloudflared restart or reachability failure). Do not use this URL. |

```bash
cat ~/.cache/deepseek-cursor-proxy/current-base-url.txt
cat ~/.cache/deepseek-cursor-proxy/pending-base-url.txt
cat ~/.cache/deepseek-cursor-proxy/stale-base-url.txt
```

If `current-base-url.txt` is missing, wait for the updater timer or inspect the cloudflared log for the latest tunnel URL.

## How the Cloudflare Tunnel Updater Works

1. `cloudflared-deepseek-quick.service` starts on boot and creates a Quick Tunnel, logging its URL to `~/.cache/deepseek-cursor-proxy/cloudflared.log`.
2. `update-cursor-deepseek-url.timer` fires 90 seconds after boot and every 90 seconds thereafter.
3. Each time the timer fires, `update-cursor-deepseek-url.sh`:
    - Scans the cloudflared log for the **newest reachable** `trycloudflare.com` URL (validates both `/healthz` and `/v1/models` are reachable).
    - Normalizes it to `https://<host>.trycloudflare.com/v1`.
    - If no reachable URL is found, moves a stale `current-base-url.txt` to `stale-base-url.txt` (no DB change).
    - Checks if Cursor is running:
        - **Cursor closed**: Patches `state.vscdb`, writes `current-base-url.txt`, removes pending file. Creates a backup in `~/Backups/cursor-state-auto/`.
        - **Cursor open**: Writes `pending-base-url.txt`, exits with code `75` so systemd retries.
4. When `cloudflared-deepseek-quick.service` restarts, it clears `current-base-url.txt` and `pending-base-url.txt` so stale URLs are not reused.
5. The timer's retry loop ensures the URL is eventually applied once Cursor is closed.

## Reboot Behavior

After a reboot:

- The proxy and tunnel services start automatically.
- The URL updater timer fires 90 seconds after boot.
- Cloudflare Quick Tunnel URLs **can change after reboot** — the updater detects the new URL and patches Cursor's database.
- If Cursor is open during reboot, the pending URL is saved and applied when Cursor is next closed.

## Files Installed

| Path | Purpose |
|------|---------|
| `~/tools/deepseek-cursor-proxy/` | Python proxy (cloned from yxlao/deepseek-cursor-proxy) |
| `~/.local/bin/cloudflared` | Cloudflare tunnel binary |
| `~/.local/bin/update-cursor-deepseek-url` | Tunnel URL updater script |
| `~/.config/systemd/user/deepseek-cursor-proxy.service` | Proxy systemd service |
| `~/.config/systemd/user/cloudflared-deepseek-quick.service` | Cloudflare tunnel systemd service |
| `~/.config/systemd/user/update-cursor-deepseek-url.service` | URL updater oneshot service |
| `~/.config/systemd/user/update-cursor-deepseek-url.timer` | URL updater timer (90s interval) |
| `~/.deepseek-cursor-proxy/config.yaml` | Proxy configuration |
| `~/.cache/deepseek-cursor-proxy/cloudflared.log` | Tunnel logs |
| `~/.cache/deepseek-cursor-proxy/current-base-url.txt` | Verified reachable tunnel base URL (includes `/v1`) |
| `~/.cache/deepseek-cursor-proxy/pending-base-url.txt` | Pending URL (Cursor open, DB update waiting) |
| `~/.cache/deepseek-cursor-proxy/stale-base-url.txt` | Invalidated old tunnel URL after restart or failure |
| `~/Backups/cursor-state-auto/` | Cursor DB backups before patching |

## Verification

Run these commands to verify everything is working:

```bash
# Check service status
systemctl --user status deepseek-cursor-proxy --no-pager
systemctl --user status cloudflared-deepseek-quick --no-pager
systemctl --user status update-cursor-deepseek-url.timer --no-pager

# View updater logs
journalctl --user -u update-cursor-deepseek-url -n 120 --no-pager

# Check applied base URL
cat ~/.cache/deepseek-cursor-proxy/current-base-url.txt

# Test the tunnel API endpoint
curl -sS "$(cat ~/.cache/deepseek-cursor-proxy/current-base-url.txt)/models"
```

If the last command returns a JSON list of models, the setup is working.

## Update

To update the setup scripts and proxy to the latest version:

```bash
# Update the setup repo
cd ~/deepseek-cursor-setup
git pull --ff-only

# Re-run the installer
./install.sh
```

The installer automatically updates the proxy via `git pull --ff-only` if it already exists.

## Uninstall

```bash
cd ~/deepseek-cursor-setup
chmod +x uninstall.sh
./uninstall.sh
```

This stops and disables all services, removes systemd unit files and the helper script, and reloads systemd. User data, config, cache, and backups are **not** automatically removed — the script prints optional cleanup commands at the end.

## Troubleshooting

### Cloudflare 1033 Error

Cloudflare error 1033 means the Quick Tunnel URL is gone or not yet reachable (common after reboot or `cloudflared` restart).

1. Check the latest tunnel URL from cloudflared logs:
   ```bash
   grep -oE 'https://[-a-z0-9]+\.trycloudflare\.com' ~/.cache/deepseek-cursor-proxy/cloudflared.log | tail -1
   ```
2. Check tunnel URL state files:
   ```bash
   echo current:; cat ~/.cache/deepseek-cursor-proxy/current-base-url.txt 2>/dev/null || echo "no current"
   echo pending:; cat ~/.cache/deepseek-cursor-proxy/pending-base-url.txt 2>/dev/null || echo "no pending"
   echo stale:; cat ~/.cache/deepseek-cursor-proxy/stale-base-url.txt 2>/dev/null || echo "no stale"
   ```
3. Close Cursor and let the updater timer retry (every ~90 seconds), or trigger manually:
   ```bash
   systemctl --user start update-cursor-deepseek-url.service
   ```
4. If `current-base-url.txt` is missing, wait for the updater or inspect cloudflared logs — do not reuse a URL from `stale-base-url.txt`.

If DNS is still propagating, wait 30–60 seconds and try again.

### Quick Tunnel DNS Not Ready

The updater script waits up to 120 seconds for the tunnel URL to become reachable. If it still fails, check:

```bash
journalctl --user -u cloudflared-deepseek-quick --no-pager -n 50
```

### Cursor Still Using Old URL

If Cursor was open when the tunnel URL changed, the updater cannot patch `state.vscdb`. Close Cursor and wait up to 90 seconds for the timer to retry. You can also trigger the update manually:

```bash
systemctl --user start update-cursor-deepseek-url.service
```

Check the logs:

```bash
journalctl --user -u update-cursor-deepseek-url --no-pager -n 120
```

### Cursor Running Prevents DB Patch

When Cursor is open, the updater saves the pending URL to:

```
~/.cache/deepseek-cursor-proxy/pending-base-url.txt
```

Close Cursor, and the timer will apply it on the next retry. A desktop notification is also sent if `notify-send` is available.

### Missing Dependencies

If the installer reports missing dependencies:

```bash
sudo apt install -y git curl python3 sqlite3 ripgrep
```

Note: `rg` is called `ripgrep` on Ubuntu/Debian, not `rg` in the package name.

### Where to Find Logs

```bash
# Proxy logs
journalctl --user -u deepseek-cursor-proxy -f

# Tunnel logs
journalctl --user -u cloudflared-deepseek-quick -f
# Also written to:
cat ~/.cache/deepseek-cursor-proxy/cloudflared.log

# URL updater logs
journalctl --user -u update-cursor-deepseek-url -n 120 --no-pager
```

## Security Notes

- Your DeepSeek API key is entered in Cursor and is **never stored** by this repo — it passes through the proxy transparently.
- The Cloudflare tunnel exposes the proxy to the public internet. The `trycloudflare.com` URL is unguessable and temporary, but treat it as a secret.
- The proxy listens only on `127.0.0.1` (localhost), not on all interfaces.
- Backups of Cursor's `state.vscdb` are created before patching, so you can restore if needed.

## Limitations

- Cloudflare Quick Tunnel URLs change after each reboot (or tunnel restart). The auto-updater handles this, but it means the Base URL in Cursor is not stable.
- The URL updater must wait for Cursor to be closed before it can patch the SQLite database.
- Designed for a single user with one Cursor installation. Multi-user setups would need configuration adjustments.
- The tunnel adds some latency compared to connecting directly to the DeepSeek API.

## Credits

- [deepseek-cursor-proxy](https://github.com/yxlao/deepseek-cursor-proxy) by Yixing Lao — the proxy that makes this all work
- [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/) — free reverse tunneling
