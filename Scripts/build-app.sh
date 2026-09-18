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
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN/JustArc" "$APP/Contents/MacOS/JustArc"

# SwiftPM compiles against the current SDK but stamps the binary with the deployment
# target as its SDK version. macOS picks an app's appearance from that stamp, so a
# binary claiming the macOS 14 SDK is shown the old design even on macOS 26, with no
# Liquid Glass in the toolbar. Record the SDK it was actually built with; the
# deployment target, and so the oldest macOS it runs on, is left alone.
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
MIN_VERSION="$(otool -l "$APP/Contents/MacOS/JustArc" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')"
xcrun vtool -set-build-version macos "$MIN_VERSION" "$SDK_VERSION" -replace \
  -output "$APP/Contents/MacOS/JustArc" "$APP/Contents/MacOS/JustArc" 2>/dev/null
echo "Stamped SDK $SDK_VERSION (runs on macOS $MIN_VERSION and later)"
cp "$ROOT/Sources/JustArc/Resources/Info.plist" "$APP/Contents/Info.plist"
# 7-Zip's format library, loaded in process. It is not a framework, but Frameworks
# is where the hardened runtime expects code the app loads.
mkdir -p "$APP/Contents/Frameworks"
cp "$ROOT/Vendor/7z.so" "$APP/Contents/Frameworks/7z.so"
cp "$ROOT/Vendor/7zz-License.txt" "$APP/Contents/Resources/7-Zip-License.txt"
cp "$ROOT/Sources/JustArc/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Localizations. Each .lproj folder is copied as-is next to the other resources.
for lproj in "$ROOT/Sources/JustArc/Resources/"*.lproj; do
  [ -d "$lproj" ] || continue
  cp -R "$lproj" "$APP/Contents/Resources/"
done
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
codesign --force --sign - --timestamp=none "$APP/Contents/Frameworks/7z.so" 2>/dev/null || true
codesign --force --deep --sign - --timestamp=none "$APP" 2>/dev/null || true

echo "Built $APP"
