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
cp "$ROOT/Sources/JustArc/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Localizations. Each .lproj folder is copied as-is next to the other resources.
for lproj in "$ROOT/Sources/JustArc/Resources/"*.lproj; do
  [ -d "$lproj" ] || continue
  cp -R "$lproj" "$APP/Contents/Resources/"
done
chmod +x "$APP/Contents/Helpers/7zz"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Sparkle ships as a universal XCFramework. Embed the macOS slice and give the
# executable an rpath that points at it inside the bundle.
SPARKLE="$ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [ -d "$SPARKLE" ]; then
  mkdir -p "$APP/Contents/Frameworks"
  rm -rf "$APP/Contents/Frameworks/Sparkle.framework"
  cp -R "$SPARKLE" "$APP/Contents/Frameworks/"
  if ! otool -l "$APP/Contents/MacOS/JustArc" | grep -q "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/JustArc" 2>/dev/null || true
  fi
  # Drop rpaths that point back into the build tree: they do not exist on another Mac,
  # and while they are present the app loads Sparkle from there instead of the bundle.
  # A release build has none of these, so the grep must not fail the script.
  STALE_RPATHS="$(otool -l "$APP/Contents/MacOS/JustArc" \
    | awk '/LC_RPATH/{f=1} f&&/path /{print $2; f=0}' | grep "/\.build/" || true)"
  for stale in $STALE_RPATHS; do
    install_name_tool -delete_rpath "$stale" "$APP/Contents/MacOS/JustArc" 2>/dev/null || true
  done
else
  echo "warning: Sparkle.framework not found; the updater will be unavailable" >&2
fi

# Ad-hoc signing keeps Gatekeeper quiet locally; a real build signs with a Developer ID.
codesign --force --sign - --timestamp=none "$APP/Contents/Helpers/7zz" 2>/dev/null || true
codesign --force --deep --sign - --timestamp=none "$APP" 2>/dev/null || true

echo "Built $APP"
