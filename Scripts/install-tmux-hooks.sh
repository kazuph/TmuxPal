#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
hook_script="$repo_dir/Scripts/tmux-ai-pet-hook.sh"
tmux_bin="${TMUX_BIN:-/opt/homebrew/bin/tmux}"
hook_slot="${TMUX_AI_PET_HOOK_SLOT:-900}"

if [[ ! -x "$hook_script" ]]; then
  chmod +x "$hook_script"
fi

if [[ ! -x "$tmux_bin" ]]; then
  tmux_bin="$(command -v tmux)"
fi

install_hook() {
  local hook_name="$1"
  "$tmux_bin" set-hook -g "${hook_name}[${hook_slot}]" \
    "run-shell -b '\"${hook_script}\" \"${hook_name}\" \"#{session_name}\" \"#{window_index}\" \"#{window_id}\" \"#{pane_index}\" \"#{pane_id}\" \"#{pane_current_command}\" \"#{pane_current_path}\" \"#{pane_title}\"'"
}

install_hook after-new-window
install_hook after-split-window
install_hook after-select-window
install_hook after-select-pane
install_hook pane-exited
install_hook pane-died

echo "tmux-ai-pet hooks installed in slot ${hook_slot}."
