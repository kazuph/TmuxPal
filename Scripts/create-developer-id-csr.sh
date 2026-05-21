#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
out_dir="${1:-$repo_dir/dist/signing}"
key_path="$out_dir/DeveloperIDApplication.key"
csr_path="$out_dir/DeveloperIDApplication.certSigningRequest"

mkdir -p "$out_dir"

if [[ -e "$key_path" || -e "$csr_path" ]]; then
  echo "Refusing to overwrite existing signing files in $out_dir" >&2
  echo "Move them away or pass a new output directory." >&2
  exit 1
fi

read -r -p "Apple ID email: " apple_id
read -r -p "Certificate common name [Developer ID Application]: " common_name
common_name="${common_name:-Developer ID Application}"

openssl req \
  -new \
  -newkey rsa:2048 \
  -nodes \
  -keyout "$key_path" \
  -out "$csr_path" \
  -subj "/emailAddress=${apple_id}/CN=${common_name}/C=JP" >/dev/null 2>&1

chmod 600 "$key_path"

cat <<EOF
Created:
  $csr_path
  $key_path

Next:
  1. Open Apple Developer Certificates, Identifiers & Profiles.
  2. Create a Developer ID Application certificate.
  3. Upload this CSR:
     $csr_path
  4. Download the resulting .cer file.
  5. Run:
     ./Scripts/setup-release-signing.sh --certificate /path/to/developerID_application.cer --private-key "$key_path"
EOF
