<p align="center">
  <img src="Design/IconProposals/tmuxpal-icon.png" width="160" alt="TmuxPal app icon">
</p>

# TmuxPal

TmuxPal is a macOS menu bar companion for people who run coding agents inside
tmux. It watches your tmux server, finds active AI coding panes, and keeps a
small floating pal on screen with live status bubbles, pane shortcuts, and
Codex and Claude Code usage rings.

It is built as a native AppKit app and runs separately from Codex.app, Claude
Code, GitHub Copilot CLI, and opencode.

## What It Shows

- A draggable floating pal that stays above normal windows.
- One compact bubble per detected AI pane, including tool, repository/window,
  status, and a short task title.
- A menu bar icon that uses the currently selected pal image.
- Optional Codex and Claude Code usage rings around the pal, including
  even-spend pace markers (Claude rings outside in coral, Codex rings inside in
  pal-derived colors).
- A screenshot mode for exporting clean demo PNGs without exposing real panes.

Clicking a bubble focuses the matching tmux pane. Dragging the pal moves it and
saves the position locally.

By default the overlay is a regular window, not an always-on-top panel: other
windows can cover it, and TmuxPal leaves it wherever your window management
puts it. When an AI pane finishes a run that has not been acknowledged yet,
the overlay raises itself to the front once so you notice the completion.
TmuxPal also appears in the Dock and the Cmd+Tab app switcher, so selecting it
there brings the overlay forward at any time. Turn on "Always on Top" in the
menu bar menu to keep it floating above all windows like in older releases.

## Supported Agent TUIs

TmuxPal detects these tools when they are running inside tmux panes:

- Codex CLI: `codex`, including node-backed `bin/codex` launchers.
- Claude Code: `claude` command, process arguments, or pane titles.
- GitHub Copilot CLI: `copilot` command, process arguments, or pane titles.
- opencode: `opencode` command, process arguments, or pane titles.

Detection combines tmux pane metadata, current command, process arguments, pane
titles, and a short cached transcript tail. It works by polling tmux; hooks are
optional.

## Install

Download the latest `TmuxPal-<version>.dmg` or `TmuxPal-<version>.zip` from the
[GitHub Releases](https://github.com/kazuph/TmuxPal/releases) page, then move
`TmuxPal.app` to `/Applications` and open it.

Requirements:

- macOS 14 or later.
- `tmux` installed and running for pane detection.
- One or more supported agent CLIs running inside tmux.

If macOS blocks an unsigned or non-notarized build, use a local source build or
trust the downloaded app manually only when you are comfortable with the exact
artifact you downloaded.

Current public artifacts may be ad-hoc signed when the maintainer's Developer ID
certificate is not configured in GitHub Actions. In that case Gatekeeper can
reject the app even though the checksum matches the release. To run that
artifact locally:

```bash
xattr -dr com.apple.quarantine /Applications/TmuxPal.app
codesign --force --deep --sign - /Applications/TmuxPal.app
open /Applications/TmuxPal.app
```

This only makes your local copy launchable. It is not a substitute for Developer
ID signing and notarization for public distribution.

## CLI Signing Setup

TmuxPal can be set up for Developer ID signing mostly from the CLI. Two Apple
account steps still happen outside this repository: creating the Developer ID
certificate from the uploaded CSR, and creating an Apple app-specific password
for notarization.

Create a certificate signing request and private key:

```bash
./Scripts/create-developer-id-csr.sh
```

Upload the generated `.certSigningRequest` file to Apple Developer, create a
`Developer ID Application` certificate, and download the resulting `.cer` file.
Then store the GitHub Actions secrets:

```bash
./Scripts/setup-release-signing.sh \
  --certificate /path/to/developerID_application.cer \
  --private-key ./dist/signing/DeveloperIDApplication.key
```

If you already exported a `.p12` from Keychain Access, you can use that instead:

```bash
./Scripts/setup-release-signing.sh --p12 /path/to/DeveloperIDApplication.p12
```

The setup script stores:

- `APPLE_DEVELOPER_ID_CERTIFICATE_BASE64`
- `APPLE_DEVELOPER_ID_CERTIFICATE_PASSWORD`
- `CODESIGN_IDENTITY`
- `APPLE_ID`
- `APPLE_TEAM_ID`
- `APPLE_APP_SPECIFIC_PASSWORD`
- `KEYCHAIN_PASSWORD` (optional)

Tag releases require those signing inputs. If they are missing, GitHub Actions
fails instead of publishing ad-hoc signed public artifacts.

## Build From Source

```bash
SWIFTPM_DISABLE_SANDBOX=1 swift test --disable-sandbox
./Scripts/build_app.sh
open ./dist/TmuxPal.app
```

The app does not require `TMUX_PANE`; it polls the whole tmux server.

## Privacy And Local Data

TmuxPal is local-first:

- It reads tmux pane metadata and short pane transcript tails from your local
  tmux server.
- It stores app preferences in macOS `UserDefaults`.
- It stores optional tmux hook lifecycle events in
  `~/Library/Application Support/tmuxpal/events.jsonl`.
- It does not send tmux pane contents, titles, repository names, or pal assets
  to a TmuxPal server.

Usage rings are the only feature that can make network requests:

- Codex rings: when usage rings are enabled and Codex auth is available,
  TmuxPal reads the local `${CODEX_HOME:-$HOME/.codex}/auth.json` access token
  and calls ChatGPT's usage endpoint directly from your Mac.
- Claude rings: TmuxPal only reads a local statusline cache file. It does not
  read Claude Code credentials, access the macOS keychain, or call Anthropic's
  usage endpoint directly.

Tokens are not written into TmuxPal logs or sent anywhere else by TmuxPal.

## tmux Hooks

TmuxPal works without tmux hooks. Hooks only make pane lifecycle updates more
immediate.

The app never installs hooks silently on normal launch. Installing or removing
hooks requires an explicit confirmation dialog or a manual script command:

```bash
./Scripts/install-tmux-hooks.sh
./Scripts/uninstall-tmux-hooks.sh
```

The installer uses hook slot `900` for:

- `after-new-window`
- `after-split-window`
- `after-select-window`
- `after-select-pane`
- `pane-exited`
- `pane-died`

It unsets only that slot before writing TmuxPal's hook, so repeated installs are
idempotent and do not overwrite other hook slots.

## Pals

TmuxPal ships with Dokochan as the default pal.

The menu bar also lists custom pal directories from:

- `$HOME/.codex/tmuxpal/characters`
- `${CODEX_HOME:-$HOME/.codex}/pets`

Character directories must contain a readable manifest (`pal.json` or
`pet.json`) and a compatible sprite atlas. Codex-compatible pet atlases are
expected to be `1536x1872` PNG/WebP files with 8 columns and 9 rows of
`192x208` frames.

The status menu includes shortcuts to open Petdex and awesome-codex-pet, so you
can install a pet with its own installer and then reload TmuxPal.

## Usage Rings (Codex & Claude)

Usage rings draw ambient C-shaped bars around the selected pal when usage data
is available. Rings stack dynamically: Claude Code rings sit on the outside in
Anthropic coral, Codex rings sit on the inside.

- Claude rings show the 5-hour and 7-day (weekly) rate-limit windows.
- Codex rings prefer monthly, then weekly, then the short window, without
  inventing values for missing buckets.
- Each ring includes a grey 100% track and a small pace marker based on the
  bucket reset time and window length.

The Codex ring palette is sampled from the selected pal while filtering out
likely skin and hair tones, so outfit colors are more likely to drive the final
ring color.

### Claude Usage Data Source

Claude rings use a statusline cache file containing the `rate_limits` JSON that
Claude Code (v2.1.80+) passes to statusline scripts on stdin. Default path:
`~/.claude/cache/statusline-rate-limits.json`, overridable with the
`TMUXPAL_CLAUDE_USAGE_CACHE` environment variable. Files older than 24 hours
are ignored. `CLAUDE_CONFIG_DIR` is honored when set.

This route needs no keychain access and no network requests from TmuxPal. To
enable it, make your Claude Code statusline script persist the `rate_limits` it
receives. If you do not have a statusline yet, this minimal script is enough:

```bash
#!/bin/bash
# ~/.claude/statusline.sh — register in ~/.claude/settings.json as:
#   "statusLine": {"type": "command", "command": "~/.claude/statusline.sh"}
input=$(cat)

cache="$HOME/.claude/cache/statusline-rate-limits.json"
if echo "$input" | jq -e '.rate_limits.five_hour // .rate_limits.seven_day' >/dev/null 2>&1; then
  mkdir -p "${cache%/*}"
  echo "$input" | jq -c '{rate_limits}' > "${cache}.tmp.$$" && mv -f "${cache}.tmp.$$" "$cache"
fi

# Keep whatever statusline output you like:
echo "$input" | jq -r '.model.display_name'
```

If you already have a statusline, just add the `cache=` block to it. Note that
Claude Code only reports `rate_limits` for Claude Pro/Max subscriptions; API
key logins have no rate-limit windows, so Claude rings stay hidden.

## Launch At Login

Use the menu bar item to toggle Launch at Login.

For source builds, you can also install or remove the development LaunchAgent:

```bash
./Scripts/install-launch-agent.sh
./Scripts/uninstall-launch-agent.sh
```

This must be a LaunchAgent, not a LaunchDaemon, because the overlay needs the
logged-in Aqua GUI session.

## Releasing

Maintainers create a release by pushing a version tag:

```bash
git tag v0.9.3
git push origin v0.9.3
```

GitHub Actions runs tests, builds the app, creates a zip and dmg, writes
SHA-256 checksums, and attaches the files to the GitHub Release. When Developer
ID and notarization secrets are configured, the release workflow signs and
notarizes the artifacts; otherwise it falls back to ad-hoc signing.

Required GitHub Actions secrets for signed public artifacts:

- `CODESIGN_IDENTITY`
- `APPLE_DEVELOPER_ID_CERTIFICATE_BASE64`
- `APPLE_DEVELOPER_ID_CERTIFICATE_PASSWORD`
- `APPLE_ID`
- `APPLE_TEAM_ID`
- `APPLE_APP_SPECIFIC_PASSWORD`
- `KEYCHAIN_PASSWORD` (optional)

Verify a downloaded release before publishing or announcing it:

```bash
codesign -dv --verbose=4 /Applications/TmuxPal.app
spctl -a -vvv /Applications/TmuxPal.app
```

`Signature=adhoc` or `spctl ... rejected` means the artifact is not notarized
for normal public macOS distribution.

## License

MIT.
