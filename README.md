# tmux-ai-pet

macOS native overlay daemon for tmux-based coding AI sessions. It runs
separately from Codex.app, watches tmux panes for Codex, Claude Code, GitHub
Copilot CLI, and opencode, then shows Dokochan with stacked status bubbles.

## Features

- Floating AppKit overlay with Dokochan from the existing hatch-pet atlas.
- Detects all AI panes in tmux, not just the active pane.
- Shows `tool · repo/window · status · short title` bubbles.
- Drag the pet to move it; the position is saved in `UserDefaults`.
- Dragging switches Dokochan to running animations.
- Bubble click focuses the matching tmux pane.
- Optional tmux hooks append lifecycle events to:
  `~/Library/Application Support/tmux-ai-pet/events.jsonl`.
- Starts `codex app-server` with `gpt-5.5` and low reasoning when available.

## Build And Run

```bash
SWIFTPM_DISABLE_SANDBOX=1 swift test --disable-sandbox
./Scripts/build_app.sh
open ./dist/TmuxAiPet.app
```

The app does not require `TMUX_PANE`; it polls the whole tmux server.

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

Install lightweight event hooks:

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

## Pet Assets

Default assets:

- `$HOME/.codex/pets/dokochan/spritesheet.webp`
- `$HOME/.codex/pets/dokochan/pet.json`

Initial version is intentionally Dokochan-only.
