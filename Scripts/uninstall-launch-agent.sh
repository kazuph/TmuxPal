#!/usr/bin/env bash
set -euo pipefail

label="dev.tmuxpal"
plist_path="$HOME/Library/LaunchAgents/${label}.plist"
launchctl bootout "gui/$(id -u)" "$plist_path" >/dev/null 2>&1 || true
rm -f "$plist_path"
echo "LaunchAgent removed."
