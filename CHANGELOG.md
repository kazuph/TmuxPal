# Changelog

## v0.9.15

TmuxPal v0.9.15 stops Claude usage rings from prompting for Claude Code
keychain access.

### Highlights

- Claude usage rings now read only the local Claude Code statusline cache.
  TmuxPal no longer falls back to `~/.claude/.credentials.json`, the macOS
  keychain item `Claude Code-credentials`, or Anthropic's OAuth usage
  endpoint.
- When no fresh statusline cache exists, Claude rings stay hidden instead of
  asking macOS for access to Claude Code credentials.

### Verification

- `swift test`
- Confirmed the app binary no longer contains `Claude Code-credentials`,
  `api/oauth/usage`, `.credentials.json`, or `SecItem` strings.
- Replaced and launched `/Applications/TmuxPal.app`; no `SecurityAgent`
  keychain prompt process appeared after launch.

## v0.9.8

TmuxPal v0.9.8 ships a new app icon for its new life in the Dock.

### Highlights

- New "Cat on Top" app icon: a cozy pixel-art cat hugging the terminal window
  while holding up a green task-complete badge. Generated with Codex image
  generation; picked from three candidates. Replaces the icon shown in the
  Dock, Cmd+Tab switcher, and README.
- The artwork is composited onto a full-bleed dark gradient background so
  macOS 26 clips it into its own squircle instead of mounting the transparent
  art on a white system plate.

### Verification

- Icon rendered from a 1024x1024 transparent PNG into a full
  `AppIcon.iconset` (16-1024px) via `iconutil`; small-size readability
  checked at 64px.
- `swift test` and a local app build with the new `AppIcon.icns` bundled.

## v0.9.7

TmuxPal v0.9.7 makes the app selectable like any other app, so the overlay is
one Cmd+Tab away.

### Highlights

- TmuxPal now uses the regular app activation policy: it shows up in the Dock
  and the Cmd+Tab app switcher. Selecting it (Cmd+Tab or Dock click) raises
  the overlay to the front, re-showing it first if it was hidden.
- Added a minimal main menu (Show Overlay, Quit) for when the app is active.

### Verification

- `swift test`
- Live check against an isolated fake tmux server: activation policy reports
  `regular`, and activating the process (the Cmd+Tab equivalent) moves the
  overlay from behind Ghostty to the front of the layer-0 window ordering.

## v0.9.6

TmuxPal v0.9.6 stops keeping the overlay above all windows. The overlay is now
a regular-level window that only raises itself when a task completes.

### Highlights

- The overlay window no longer floats above everything: it sits at normal
  window level, so other windows can cover it and TmuxPal does nothing when
  they do.
- When an AI pane finishes a run that has not been acknowledged yet, the
  overlay raises itself to the front once (without stealing focus).
- Added an "Always on Top" menu toggle that restores the old always-floating
  behavior.
- Removed the v0.9.5 auto-collapsing bubble mode and its "Always Show
  Bubbles" toggle; bubbles behave like v0.9.4 again. The v0.9.5 fix for
  inactive tmux panes being misclassified as running is kept, since completion
  detection depends on it.

### Verification

- `swift test`
- End-to-end check against an isolated fake tmux server with
  `CGWindowListCopyWindowInfo`: idle overlay sits at window layer 0 (normal
  level) instead of 25, and jumps to the front of the layer-0 ordering when a
  fake pane prints a completion marker.

## v0.9.5

TmuxPal v0.9.5 stops showing the full bubble stack all the time. The overlay
now stays collapsed by default and becomes active only when something happens.

### Highlights

- New default "active only" bubble visibility: the bubble stack stays
  collapsed (pal plus completed-count badge) and expands automatically while a
  pane is running or a finished run is still unacknowledged. Acknowledging the
  pane (clicking its bubble or focusing it in tmux) collapses the stack again.
- Added an "Always Show Bubbles" toggle to the menu bar menu to restore the
  previous always-expanded behavior.
- Fixed inactive tmux panes always classifying as running: tmux panes no
  longer report a hard `.running` status, so the transcript-marker based run
  detection works as intended (herdr panes keep their reliable status).

### Verification

- `swift test` (37 tests, including new `BubbleActivityTracker` coverage)
- End-to-end dogfooding against an isolated fake tmux server
  (`TMUXPAL_TMUX_SOCKET`) with snapshot evidence: idle → collapsed, running →
  auto-expand, complete-unacknowledged → stays expanded, acknowledged →
  auto-collapse, and "Always Show Bubbles" → expanded while idle.

## v0.9.4

TmuxPal v0.9.4 adds Claude Code usage rings alongside the existing Codex
rings.

### Highlights

- Added Claude Code usage rings: two coral rings (5-hour and weekly windows)
  drawn outside the existing Codex rings, with the same remaining-percent
  labels and even-spend pace markers.
- Claude usage prefers a local statusline cache
  (`~/.claude/cache/statusline-rate-limits.json`, overridable with
  `TMUXPAL_CLAUDE_USAGE_CACHE`; see README for a statusline snippet) and falls
  back to Anthropic's OAuth usage endpoint with throttled polling.
- Usage ring layout is now dynamic, so any mix of Claude and Codex buckets
  stacks without overlapping.

### Verification

- `swift test`
- `Scripts/build_app.sh`
- Manual dogfooding of `/Applications/TmuxPal.app` with four rings visible
  (Claude W/5h + Codex W/5h), values cross-checked against
  `~/.claude/cache/statusline-rate-limits.json`.

## v0.9.3

TmuxPal v0.9.3 fixes herdr agent discovery when the menu bar app is launched
from Finder or Launch Services without a shell PATH.

### Highlights

- Resolve the herdr executable from `TMUXPAL_HERDR_PATH`, the current PATH, and
  common local install paths such as `~/.local/bin/herdr`.
- Keep herdr-only workflows visible even when tmux is not currently running.

### Verification

- `swift test`
- `env -i HOME="$HOME" USER="$USER" PATH="/usr/bin:/bin" .build/debug/tmuxpal --dump-panes`
- `/Applications/TmuxPal.app/Contents/MacOS/TmuxPal --dump-panes`
- Manual dogfooding of `/Applications/TmuxPal.app` with herdr agents visible

## v0.9.2

TmuxPal v0.9.2 refines the human-review status indicator so completed panes are
noticeable without overwhelming the bubble UI.

### Highlights

- Replaced the faint completed-awaiting ring with a compact solid green dot.
- Kept acknowledged completed panes visually distinct with the existing check
  mark indicator.

### Verification

- `swift test`
- `Scripts/build_app.sh`

## v0.9.1

TmuxPal v0.9.1 polishes the repository for public distribution.

### Highlights

- Reworked the README for public users, including install, privacy, tmux hooks,
  pal assets, and Codex usage-ring behavior.
- Documented the current ad-hoc signing fallback, local launch workaround, and
  Developer ID notarization requirements for public artifacts.
- Added CLI helpers for creating a Developer ID CSR and storing release signing
  secrets in GitHub Actions.
- Made tag releases fail when Developer ID signing inputs are missing instead
  of publishing ad-hoc signed public artifacts.
- Replaced the app icon with a simpler public-facing icon that keeps Dokochan,
  tmux panes, and green usage rings visible at small sizes.
- Added GitHub repository description, homepage, and topics.

### Verification

- `swift test`
- `Scripts/build_app.sh`

## v0.9.0

TmuxPal v0.9.0 is the first release shaped for daily use as a polished menu bar app.

### Highlights

- Replaced the text menu bar title with the selected pal's image.
- Added Codex usage rings around the pal, including pace markers and 100% tracks.
- Kept usage pace markers visible even when the pace falls inside the C-ring gap.
- Improved usage ring palette extraction so human-character skin and hair tones do not dominate outfit colors.
- Added Codex-compatible pet discovery from `${CODEX_HOME:-$HOME/.codex}/pets`.
- Added Petdex and awesome-codex-pet shortcuts from the menu.
- Switched all user-facing app text to English.
- Added explicit confirmation dialogs before installing or removing tmux hooks.

### tmux Hooks

TmuxPal does not install tmux hooks on normal app launch.

Hooks are optional. When installed, TmuxPal writes global tmux hooks in slot `900`
for `after-new-window`, `after-split-window`, `after-select-window`,
`after-select-pane`, `pane-exited`, and `pane-died`. Each hook runs
`tmuxpal-hook.sh` and appends a small lifecycle event record under TmuxPal's app
support directory. The app still works without hooks by polling tmux; hooks only
make lifecycle updates more immediate.

### Verification

- `swift test`
- `Scripts/build_app.sh`
- Manual dogfooding of the menu bar app, pal icon, usage rings, and tmux hook
  confirmation dialogs
