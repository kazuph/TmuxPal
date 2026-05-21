# Changelog

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
