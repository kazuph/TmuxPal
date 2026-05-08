#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$repo_dir/.build/release"
app_dir="$repo_dir/dist/TmuxAiPet.app"
contents_dir="$app_dir/Contents"
macos_dir="$contents_dir/MacOS"

cd "$repo_dir"
SWIFTPM_DISABLE_SANDBOX=1 swift build -c release --disable-sandbox

rm -rf "$app_dir"
mkdir -p "$macos_dir"
cp "$build_dir/tmux-ai-pet" "$macos_dir/TmuxAiPet"

cat > "$contents_dir/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>TmuxAiPet</string>
  <key>CFBundleIdentifier</key>
  <string>dev.tmux-ai-pet</string>
  <key>CFBundleName</key>
  <string>TmuxAiPet</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.1.0</string>
  <key>CFBundleVersion</key>
  <string>1</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST

codesign --force --sign - "$app_dir" >/dev/null 2>&1 || true
echo "$app_dir"
