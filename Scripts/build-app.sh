#!/bin/bash
# Builds JustArc.app. Xcode's toolchain is used via DEVELOPER_DIR so no
# `sudo xcode-select` is needed when only the Command Line Tools are active.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-debug}"
APP="$ROOT/build/JustArc.app"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

echo "Building JustArc ($CONFIG)…"
cd "$ROOT"
swift build --configuration "$CONFIG" --product JustArc

BIN="$(swift build --configuration "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"

cp "$BIN/JustArc" "$APP/Contents/MacOS/JustArc"
cp "$ROOT/Sources/JustArc/Resources/Info.plist" "$APP/Contents/Info.plist"
cp "$ROOT/Vendor/7zz" "$APP/Contents/Helpers/7zz"
cp "$ROOT/Vendor/7zz-License.txt" "$APP/Contents/Resources/7-Zip-License.txt"

# Localizations. Each .lproj folder is copied as-is next to the other resources.
for lproj in "$ROOT/Sources/JustArc/Resources/"*.lproj; do
  [ -d "$lproj" ] || continue
  cp -R "$lproj" "$APP/Contents/Resources/"
done
chmod +x "$APP/Contents/Helpers/7zz"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signing keeps Gatekeeper quiet locally; a real build signs with a Developer ID.
codesign --force --sign - --timestamp=none "$APP/Contents/Helpers/7zz" 2>/dev/null || true
codesign --force --deep --sign - --timestamp=none "$APP" 2>/dev/null || true

echo "Built $APP"
