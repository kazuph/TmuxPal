#!/usr/bin/env bash
set -euo pipefail

tmux_bin="${TMUX_BIN:-/opt/homebrew/bin/tmux}"
hook_slot="${TMUX_AI_PET_HOOK_SLOT:-900}"

if [[ ! -x "$tmux_bin" ]]; then
  tmux_bin="$(command -v tmux)"
fi

for hook_name in after-new-window after-split-window after-select-window after-select-pane pane-exited pane-died; do
  "$tmux_bin" set-hook -gu "${hook_name}[${hook_slot}]" 2>/dev/null || true
done

echo "tmux-ai-pet hooks removed from slot ${hook_slot}."
