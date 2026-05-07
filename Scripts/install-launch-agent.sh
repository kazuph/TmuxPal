#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_path="$repo_dir/dist/TmuxAiPet.app"
launcher_path="$repo_dir/Scripts/run-launch-agent.sh"
plist_path="$HOME/Library/LaunchAgents/com.kazuph.tmux-ai-pet.plist"

if [[ ! -d "$app_path" ]]; then
  "$repo_dir/Scripts/build_app.sh" >/dev/null
fi

mkdir -p "$HOME/Library/LaunchAgents"
chmod +x "$launcher_path"

cat > "$plist_path" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.kazuph.tmux-ai-pet</string>
  <key>ProgramArguments</key>
  <array>
    <string>${launcher_path}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <false/>
  <key>StandardOutPath</key>
  <string>${HOME}/Library/Logs/tmux-ai-pet.out.log</string>
  <key>StandardErrorPath</key>
  <string>${HOME}/Library/Logs/tmux-ai-pet.err.log</string>
</dict>
</plist>
PLIST

launchctl bootout "gui/$(id -u)" "$plist_path" >/dev/null 2>&1 || true
launchctl bootstrap "gui/$(id -u)" "$plist_path"
launchctl kickstart -k "gui/$(id -u)/com.kazuph.tmux-ai-pet"

echo "$plist_path"
