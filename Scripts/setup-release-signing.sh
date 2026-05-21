#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
repo="${GITHUB_REPOSITORY:-kazuph/TmuxPal}"
certificate_path=""
private_key_path=""
p12_path=""

usage() {
  cat <<'EOF'
Usage:
  ./Scripts/setup-release-signing.sh --p12 DeveloperIDApplication.p12
  ./Scripts/setup-release-signing.sh --certificate developerID_application.cer --private-key DeveloperIDApplication.key

This script stores GitHub Actions secrets needed to Developer ID sign and
notarize TmuxPal release artifacts. It never prints secret values.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      repo="$2"
      shift 2
      ;;
    --certificate)
      certificate_path="$2"
      shift 2
      ;;
    --private-key)
      private_key_path="$2"
      shift 2
      ;;
    --p12)
      p12_path="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if ! command -v gh >/dev/null 2>&1; then
  echo "gh is required." >&2
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "gh is not authenticated. Run gh auth login first." >&2
  exit 1
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

if [[ -n "$p12_path" ]]; then
  if [[ ! -f "$p12_path" ]]; then
    echo "p12 file not found: $p12_path" >&2
    exit 1
  fi
  working_p12="$p12_path"
elif [[ -n "$certificate_path" && -n "$private_key_path" ]]; then
  if [[ ! -f "$certificate_path" ]]; then
    echo "Certificate file not found: $certificate_path" >&2
    exit 1
  fi
  if [[ ! -f "$private_key_path" ]]; then
    echo "Private key file not found: $private_key_path" >&2
    exit 1
  fi

  read -r -s -p "New p12 export password: " p12_password
  echo
  read -r -s -p "Confirm p12 export password: " p12_password_confirm
  echo
  if [[ "$p12_password" != "$p12_password_confirm" ]]; then
    echo "Passwords did not match." >&2
    exit 1
  fi

  cert_pem="$tmp_dir/developer-id.pem"
  working_p12="$tmp_dir/DeveloperIDApplication.p12"
  openssl x509 -inform DER -in "$certificate_path" -out "$cert_pem" 2>/dev/null || \
    openssl x509 -in "$certificate_path" -out "$cert_pem" >/dev/null
  openssl pkcs12 \
    -export \
    -inkey "$private_key_path" \
    -in "$cert_pem" \
    -out "$working_p12" \
    -password "pass:$p12_password" >/dev/null 2>&1
else
  usage >&2
  exit 2
fi

if [[ -z "${p12_password:-}" ]]; then
  read -r -s -p "p12 password: " p12_password
  echo
fi

read -r -p "Codesign identity (Developer ID Application: Name (TEAMID)): " codesign_identity
read -r -p "Apple ID email for notarization: " apple_id
read -r -p "Apple Team ID: " apple_team_id
read -r -s -p "Apple app-specific password for notarytool: " apple_app_password
echo
read -r -s -p "Optional CI keychain password [leave blank for generated default]: " keychain_password
echo

if [[ -z "$codesign_identity" || -z "$apple_id" || -z "$apple_team_id" || -z "$apple_app_password" ]]; then
  echo "Codesign identity, Apple ID, Team ID, and app-specific password are required." >&2
  exit 1
fi

p12_base64="$(base64 -i "$working_p12")"

printf '%s' "$p12_base64" | gh secret set APPLE_DEVELOPER_ID_CERTIFICATE_BASE64 --repo "$repo"
printf '%s' "$p12_password" | gh secret set APPLE_DEVELOPER_ID_CERTIFICATE_PASSWORD --repo "$repo"
printf '%s' "$codesign_identity" | gh secret set CODESIGN_IDENTITY --repo "$repo"
printf '%s' "$apple_id" | gh secret set APPLE_ID --repo "$repo"
printf '%s' "$apple_team_id" | gh secret set APPLE_TEAM_ID --repo "$repo"
printf '%s' "$apple_app_password" | gh secret set APPLE_APP_SPECIFIC_PASSWORD --repo "$repo"

if [[ -n "$keychain_password" ]]; then
  printf '%s' "$keychain_password" | gh secret set KEYCHAIN_PASSWORD --repo "$repo"
fi

cat <<EOF
Stored release signing secrets for $repo.

Recommended verification:
  gh workflow run Release --repo "$repo"

For a public release, push a version tag after the workflow succeeds.
Tag builds now require Developer ID signing inputs and should fail instead of
publishing ad-hoc signed public artifacts.
EOF
