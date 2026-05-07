#!/usr/bin/env bash
set -euo pipefail

plist_path="$HOME/Library/LaunchAgents/com.kazuph.tmux-ai-pet.plist"
launchctl bootout "gui/$(id -u)" "$plist_path" >/dev/null 2>&1 || true
rm -f "$plist_path"
echo "LaunchAgent removed."
