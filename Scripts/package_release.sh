#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
version="${1:-${GITHUB_REF_NAME:-0.9.0}}"
version="${version#v}"
dist_dir="$repo_dir/dist"
app_path="$dist_dir/TmuxPal.app"
release_dir="$dist_dir/release"
dmg_root="$release_dir/dmg-root"
notary_zip_path="$release_dir/TmuxPal-${version}-notary.zip"

/bin/rm -rf "$release_dir"
/bin/mkdir -p "$release_dir"
trap '/bin/rm -rf "$dmg_root"' EXIT

TMUXPAL_VERSION="$version" "$repo_dir/Scripts/build_app.sh" >/dev/null

zip_path="$release_dir/TmuxPal-${version}.zip"
dmg_path="$release_dir/TmuxPal-${version}.dmg"
checksum_path="$release_dir/checksums.txt"

if [[ "${TMUXPAL_REQUIRE_NOTARIZATION:-}" == "1" ]]; then
  missing=()
  [[ -n "${APPLE_ID:-}" ]] || missing+=("APPLE_ID")
  [[ -n "${APPLE_TEAM_ID:-}" ]] || missing+=("APPLE_TEAM_ID")
  [[ -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]] || missing+=("APPLE_APP_SPECIFIC_PASSWORD")
  [[ -n "${CODESIGN_IDENTITY:-}" ]] || missing+=("CODESIGN_IDENTITY")
  if (( ${#missing[@]} > 0 )); then
    printf 'Missing signing inputs for public release: %s\n' "${missing[*]}" >&2
    exit 1
  fi
fi

if [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" && -n "${CODESIGN_IDENTITY:-}" ]]; then
  ditto -c -k --keepParent "$app_path" "$notary_zip_path"
  xcrun notarytool submit "$notary_zip_path" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_SPECIFIC_PASSWORD" \
    --wait
  xcrun stapler staple "$app_path"
  spctl -a -vvv "$app_path"
  /bin/rm -f "$notary_zip_path"
fi

ditto -c -k --keepParent "$app_path" "$zip_path"
/bin/mkdir -p "$dmg_root"
/bin/cp -R "$app_path" "$dmg_root/"
/bin/ln -s /Applications "$dmg_root/Applications"
hdiutil create \
  -volname "TmuxPal" \
  -srcfolder "$dmg_root" \
  -ov \
  -format UDZO \
  "$dmg_path" >/dev/null
/bin/rm -rf "$dmg_root"

if [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" && -n "${CODESIGN_IDENTITY:-}" ]]; then
  codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$dmg_path"
  xcrun notarytool submit "$dmg_path" \
    --apple-id "$APPLE_ID" \
    --team-id "$APPLE_TEAM_ID" \
    --password "$APPLE_APP_SPECIFIC_PASSWORD" \
    --wait
  xcrun stapler staple "$dmg_path"
  # Disk images need an explicit assessment context; a bare `spctl -t open`
  # reports "Insufficient Context" even for notarized, stapled images.
  spctl -a -vvv -t open --context context:primary-signature "$dmg_path"
fi

(
  cd "$release_dir"
  shasum -a 256 "TmuxPal-${version}.zip" "TmuxPal-${version}.dmg" > "$checksum_path"
)

echo "$release_dir"
