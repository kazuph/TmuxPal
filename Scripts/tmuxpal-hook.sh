#!/usr/bin/env bash
set -euo pipefail

event="${1:-unknown}"
session_name="${2:-}"
window_index="${3:-}"
window_id="${4:-}"
pane_index="${5:-}"
pane_id="${6:-}"
pane_current_command="${7:-}"
pane_current_path="${8:-}"
pane_title="${9:-}"

support_dir="${HOME}/Library/Application Support/tmuxpal"
events_file="${support_dir}/events.jsonl"
mkdir -p "$support_dir"

/usr/bin/python3 - "$events_file" "$event" "$session_name" "$window_index" "$window_id" "$pane_index" "$pane_id" "$pane_current_command" "$pane_current_path" "$pane_title" <<'PY'
import json
import sys
from datetime import datetime, timezone

events_file = sys.argv[1]
payload = {
    "event": sys.argv[2],
    "sessionName": sys.argv[3],
    "windowIndex": sys.argv[4],
    "windowId": sys.argv[5],
    "paneIndex": sys.argv[6],
    "paneId": sys.argv[7],
    "paneCurrentCommand": sys.argv[8],
    "paneCurrentPath": sys.argv[9],
    "paneTitle": sys.argv[10],
    "createdAt": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
}
with open(events_file, "a", encoding="utf-8") as f:
    f.write(json.dumps(payload, ensure_ascii=False, separators=(",", ":")) + "\n")
PY
