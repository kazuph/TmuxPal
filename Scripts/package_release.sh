#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
version="${1:-${GITHUB_REF_NAME:-0.1.0}}"
version="${version#v}"
dist_dir="$repo_dir/dist"
app_path="$dist_dir/TmuxAiPet.app"
release_dir="$dist_dir/release"
dmg_root="$release_dir/dmg-root"

rm -rf "$release_dir"
mkdir -p "$release_dir"

TMUX_AI_PET_VERSION="$version" "$repo_dir/Scripts/build_app.sh" >/dev/null

zip_path="$release_dir/TmuxAiPet-${version}.zip"
dmg_path="$release_dir/TmuxAiPet-${version}.dmg"
checksum_path="$release_dir/checksums.txt"

ditto -c -k --keepParent "$app_path" "$zip_path"
mkdir -p "$dmg_root"
cp -R "$app_path" "$dmg_root/"
ln -s /Applications "$dmg_root/Applications"
hdiutil create \
  -volname "TmuxAiPet" \
  -srcfolder "$dmg_root" \
  -ov \
  -format UDZO \
  "$dmg_path" >/dev/null
rm -rf "$dmg_root"

(
  cd "$release_dir"
  shasum -a 256 "TmuxAiPet-${version}.zip" "TmuxAiPet-${version}.dmg" > "$checksum_path"
)

echo "$release_dir"
