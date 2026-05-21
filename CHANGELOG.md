# Changelog

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
