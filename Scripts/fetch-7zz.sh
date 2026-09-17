#!/bin/bash
# Refreshes Vendor/7zz from the official 7-Zip release. The binary is a universal
# Mach-O (x86_64 + arm64) and is redistributed under the GNU LGPL.
set -euo pipefail

VERSION="${1:-2501}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "Fetching 7-Zip $VERSION for macOS…"
curl -fsSL -o "$TMP/7z.tar.xz" "https://www.7-zip.org/a/7z${VERSION}-mac.tar.xz"
tar -xf "$TMP/7z.tar.xz" -C "$TMP"

file "$TMP/7zz" | grep -q "universal binary" || {
  echo "Downloaded 7zz is not a universal binary." >&2
  exit 1
}

mkdir -p "$ROOT/Vendor"
cp "$TMP/7zz" "$ROOT/Vendor/7zz"
cp "$TMP/License.txt" "$ROOT/Vendor/7zz-License.txt"
chmod +x "$ROOT/Vendor/7zz"
"$ROOT/Vendor/7zz" i | head -3
