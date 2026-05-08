#!/usr/bin/env zsh
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
app_bin="$repo_dir/dist/TmuxPal.app/Contents/MacOS/TmuxPal"

current_user="$(id -un)"
export HOME="${HOME:-$(eval "echo ~$current_user")}"
export USER="${USER:-$current_user}"
export LOGNAME="${LOGNAME:-$current_user}"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export TMUXPAL_TMUX_SOCKET="${TMUXPAL_TMUX_SOCKET:-/private/tmp/tmux-$(id -u)/default}"

exec "$app_bin"
