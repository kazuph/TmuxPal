<p align="center">
  <img src="Design/IconProposals/tmuxpal-icon.png" width="160" alt="TmuxPal icon">
</p>

# TmuxPal

macOS native overlay daemon for tmux-based coding AI sessions. It runs
separately from Codex.app, watches tmux panes for Codex, Claude Code, GitHub
Copilot CLI, and opencode, then shows Dokochan with stacked status bubbles.

## Features

- Floating AppKit overlay with bundled Dokochan assets.
- Detects all AI panes in tmux, not just the active pane.
- Shows `tool · repo/window · status · short title` bubbles.
- Drag the pal to move it; the position is saved in `UserDefaults`.
- Dragging switches Dokochan to running animations.
- Bubble click focuses the matching tmux pane.
- Menu bar app only: no Dock icon and no settings window.
- Select a custom pal from the menu bar by choosing a folder that contains
  `pal.json`.
- Select pal size from the menu bar. The current display size is `Small`; `Medium`
  and `Large` scale the pal while preserving its screen position.
- Toggle "Launch at Login" from the menu bar.
- tmux hooks append lifecycle events to:
  `~/Library/Application Support/tmuxpal/events.jsonl`.
- Starts `codex app-server` with `gpt-5.5` and low reasoning when available.

## Supported Harnesses

TmuxPal detects these AI coding TUIs when they are running inside tmux panes:

- Codex CLI: `codex`, including node-backed `bin/codex` launchers.
- Claude Code: `claude` command, process arguments, or pane titles.
- GitHub Copilot CLI: `copilot` command, process arguments, or pane titles.
- opencode: `opencode` command, process arguments, or pane titles.

Detection combines tmux pane metadata, current command, process arguments, and
pane titles. Hooks improve lifecycle timing, while polling keeps the overlay
working even when a hook event is missed.

## Build And Run

```bash
SWIFTPM_DISABLE_SANDBOX=1 swift test --disable-sandbox
./Scripts/build_app.sh
open ./dist/TmuxPal.app
```

The app does not require `TMUX_PANE`; it polls the whole tmux server.

## Install From GitHub Release

Download either `TmuxPal-<version>.dmg` or `TmuxPal-<version>.zip` from a
GitHub Release, then move `TmuxPal.app` to `/Applications` and open it once.

The release artifacts are unsigned unless Developer ID signing credentials are added
to CI, so macOS Gatekeeper may require right-clicking the app and choosing
Open. For fully public distribution, add Developer ID signing and notarization
to the release workflow.

Create a release by pushing a version tag:

```bash
git tag v0.1.0
git push origin v0.1.0
```

GitHub Actions runs tests, builds the app, creates a zip, creates a dmg, writes
SHA-256 checksums, and attaches all files to the GitHub Release.

## LaunchAgent

Install as a per-user LaunchAgent:

```bash
./Scripts/install-launch-agent.sh
```

Remove it:

```bash
./Scripts/uninstall-launch-agent.sh
```

This must be a LaunchAgent, not a LaunchDaemon, because the overlay needs the
logged-in Aqua GUI session.

## tmux Hooks

TmuxPal installs lightweight event hooks on app launch. You can also reinstall
them manually:

```bash
./Scripts/install-tmux-hooks.sh
```

Remove them:

```bash
./Scripts/uninstall-tmux-hooks.sh
```

The installer only uses hook slot `900` for:

- `after-new-window`
- `after-split-window`
- `after-select-window`
- `after-select-pane`
- `pane-exited`
- `pane-died`

It does not overwrite other hook slots.
The same slot is unset before it is set, so repeated installs are idempotent and
do not duplicate hooks.

## Pal Assets

Default assets:

- bundled `Characters/dokochan/spritesheet.webp`
- bundled `Characters/dokochan/pal.json`

The menu bar lists pal directories found under `$HOME/.codex/tmuxpal/characters` when they
contain `pal.json`. If no characters are found there, the selector falls back to a
file picker. Relative `spritesheetPath` entries are resolved from the selected
pal directory.

## License

MIT.
