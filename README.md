# tmux-ai-pet

macOS native overlay daemon for tmux-based coding AI sessions. It runs
separately from Codex.app, watches tmux panes for Codex, Claude Code, GitHub
Copilot CLI, and opencode, then shows Dokochan with stacked status bubbles.

## Features

- Floating AppKit overlay with bundled Dokochan assets.
- Detects all AI panes in tmux, not just the active pane.
- Shows `tool · repo/window · status · short title` bubbles.
- Drag the pet to move it; the position is saved in `UserDefaults`.
- Dragging switches Dokochan to running animations.
- Bubble click focuses the matching tmux pane.
- Menu bar app only: no Dock icon and no settings window.
- Select a custom pet from the menu bar by choosing a folder that contains
  `pet.json`.
- Toggle "Launch at Login" from the menu bar.
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

## Install From GitHub Release

Download either `TmuxAiPet-<version>.dmg` or `TmuxAiPet-<version>.zip` from a
GitHub Release, then move `TmuxAiPet.app` to `/Applications` and open it once.

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

- bundled `Pets/dokochan/spritesheet.webp`
- bundled `Pets/dokochan/pet.json`

The app can also load a custom pet directory from the menu bar. The selected
directory must contain `pet.json`; relative `spritesheetPath` entries are
resolved from that directory.

## License

MIT.
