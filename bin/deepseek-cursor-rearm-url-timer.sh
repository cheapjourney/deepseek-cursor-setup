#!/usr/bin/env bash
# deepseek-cursor-rearm-url-timer.sh
# Restart the URL updater timer and kick its oneshot service so retry scheduling arms.
# OnUnitInactiveSec= only schedules after the service transitions active→inactive; boot-prepare
# and the pending-watcher often run the updater directly, leaving the timer in elapsed/n/a.
set -euo pipefail

systemctl --user daemon-reload >/dev/null 2>&1 || true
systemctl --user restart update-cursor-deepseek-url.timer
systemctl --user start update-cursor-deepseek-url.service
