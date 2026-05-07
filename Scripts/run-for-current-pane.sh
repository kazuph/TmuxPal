#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${TMUX_PANE:-}" ]]; then
  echo "TMUX_PANE is not set. Run this script from inside tmux." >&2
  exit 2
fi

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec swift run --package-path "$repo_dir" tmux-ai-pet
