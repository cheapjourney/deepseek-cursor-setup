# DeepSeek Cursor Proxy — Plug-and-Play Setup

One-command setup to run DeepSeek models (`deepseek-v4-pro`, `deepseek-v4-flash`) in Cursor with thinking mode, reasoning display, and a Cloudflare reverse tunnel.

## Quick Start (after fresh Ubuntu install)

```bash
git clone https://github.com/YOUR_USER/deepseek-cursor-setup.git
cd deepseek-cursor-setup
chmod +x install.sh
./install.sh
```

That's it. The proxy runs on `127.0.0.1:9000` and is exposed via a Cloudflare Quick Tunnel.

## What Gets Installed

| Component | What it does |
|---|---|
| `deepseek-cursor-proxy` (port 9000) | Forwards Cursor → DeepSeek API, fixes `reasoning_content` for tool calls |
| Cloudflare Tunnel | Exposes the local proxy via a public `*.trycloudflare.com` URL |
| URL updater (timer) | Auto-updates Cursor's DB with the tunnel URL after each reboot; retries until Cursor is closed |
| systemd user services | All components auto-start at login |

## What You Need

- **DeepSeek API key** (configured in Cursor, not stored in this repo)
- Ubuntu 24.04+ (or any Linux with systemd)
- Dependencies auto-installed: `git`, `curl`, `python3`, `sqlite3`, `ripgrep`, `uv`

## Cursor Configuration

After install, in Cursor Settings → Models:

- **Model**: `deepseek-v4-pro` (thinking) or `deepseek-v4-flash` (fast)
- **API Key**: Your DeepSeek API key
- **Base URL**: The tunnel URL (including `/v1`) — auto-updated by the timer, or find it with:
  ```bash
  cat ~/.cache/deepseek-cursor-proxy/current-base-url.txt
  # or while waiting for the updater:
  cat ~/.cache/deepseek-cursor-proxy/pending-base-url.txt
  ```

If Cursor is open when the tunnel URL changes after reboot, the updater saves a pending URL and retries every ~90 seconds until Cursor is closed and the SQLite DB can be patched.

## Management

```bash
# Status
systemctl --user status deepseek-cursor-proxy cloudflared-deepseek-quick

# Restart proxy
systemctl --user restart deepseek-cursor-proxy

# Logs
journalctl --user -u deepseek-cursor-proxy -f
journalctl --user -u cloudflared-deepseek-quick -f

# Check applied / pending tunnel URL
cat ~/.cache/deepseek-cursor-proxy/current-base-url.txt
cat ~/.cache/deepseek-cursor-proxy/pending-base-url.txt

# Updater logs
journalctl --user -u update-cursor-deepseek-url -n 120 --no-pager

# Verify tunnel API
curl -sS "$(cat ~/.cache/deepseek-cursor-proxy/current-base-url.txt)/models"
```

## Files

```
deepseek-cursor-setup/
├── install.sh                              # Main installer
├── config/config.yaml                      # Proxy configuration
├── systemd/
│   ├── deepseek-cursor-proxy.service       # Proxy service
│   ├── cloudflared-deepseek-quick.service  # Tunnel service
│   ├── update-cursor-deepseek-url.service  # URL updater (oneshot)
│   └── update-cursor-deepseek-url.timer    # URL updater timer
├── bin/update-cursor-deepseek-url.sh       # URL update script
├── README.md
└── .gitignore
```

## Credits

- [deepseek-cursor-proxy](https://github.com/yxlao/deepseek-cursor-proxy) by Yixing Lao
- [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/)
