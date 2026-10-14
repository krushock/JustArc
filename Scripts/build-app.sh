#!/bin/bash
# Builds JustArc.app. Xcode's toolchain is used via DEVELOPER_DIR so no
# `sudo xcode-select` is needed when only the Command Line Tools are active.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${1:-debug}"
APP="$ROOT/build/JustArc.app"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# A release runs on both Apple silicon and Intel, as the bundled 7z.so and Sparkle
# already do. A debug build is for this Mac only, and builds in half the time.
ARCHS=()
if [ "$CONFIG" = "release" ]; then
  ARCHS=(--arch arm64 --arch x86_64)
fi

echo "Building JustArc ($CONFIG)…"
cd "$ROOT"
swift build --configuration "$CONFIG" --product JustArc ${ARCHS[@]+"${ARCHS[@]}"}
swift build --configuration "$CONFIG" --product JustArcQuickLook ${ARCHS[@]+"${ARCHS[@]}"}

BIN="$(swift build --configuration "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN/JustArc" "$APP/Contents/MacOS/JustArc"

# SwiftPM compiles against the current SDK but stamps the binary with the deployment
# target as its SDK version. macOS picks an app's appearance from that stamp, so a
# binary claiming the macOS 14 SDK is shown the old design even on macOS 26, with no
# Liquid Glass in the toolbar. Record the SDK it was actually built with; the
# deployment target, and so the oldest macOS it runs on, is left alone.
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
stamp_sdk() {
  local min
  min="$(otool -l "$1" | awk '/LC_BUILD_VERSION/{f=1} f&&/minos/{print $2; exit}')"
  xcrun vtool -set-build-version macos "$min" "$SDK_VERSION" -replace -output "$1" "$1"
  echo "Stamped SDK $SDK_VERSION on $(basename "$1") (runs on macOS $min and later)"
}
stamp_sdk "$APP/Contents/MacOS/JustArc"

# Drops rpaths that point back into the build tree: they do not exist on another Mac,
# and while they are present the app loads Sparkle from there instead of the bundle.
# A release build has none of these, so the grep must not fail the script.
drop_build_rpaths() {
  local stale
  for stale in $(otool -l "$1" | awk '/LC_RPATH/{f=1} f&&/path /{print $2; f=0}' | grep "/\.build/" || true); do
    install_name_tool -delete_rpath "$stale" "$1" 2>/dev/null || true
  done
}
cp "$ROOT/Sources/JustArc/Resources/Info.plist" "$APP/Contents/Info.plist"
# 7-Zip's format library, loaded in process. It is not a framework, but Frameworks
# is where the hardened runtime expects code the app loads.
mkdir -p "$APP/Contents/Frameworks"
cp "$ROOT/Vendor/7z.so" "$APP/Contents/Frameworks/7z.so"
cp "$ROOT/Vendor/7zz-License.txt" "$APP/Contents/Resources/7-Zip-License.txt"
# Sparkle is MIT licensed, which asks that its notice go wherever it goes.
cp "$ROOT/.build/artifacts/sparkle/Sparkle/LICENSE" "$APP/Contents/Resources/Sparkle-License.txt"
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
  drop_build_rpaths "$APP/Contents/MacOS/JustArc"
else
  # The executable links Sparkle, so a bundle without it would not launch at all.
  echo "error: Sparkle.framework not found at $SPARKLE" >&2
  exit 1
fi

# The Quick Look extension: pressing Space on an archive in the Finder lists what is
# in it. An extension is a bundle of its own inside the app's PlugIns folder. It
# carries its own copy of 7z.so: it is sandboxed, and the sandbox does not let it
# open the app's.
APPEX="$APP/Contents/PlugIns/JustArcQuickLook.appex"
mkdir -p "$APPEX/Contents/MacOS" "$APPEX/Contents/Resources" "$APPEX/Contents/Frameworks"
cp "$ROOT/Vendor/7z.so" "$APPEX/Contents/Frameworks/7z.so"
cp "$BIN/JustArcQuickLook" "$APPEX/Contents/MacOS/JustArcQuickLook"
stamp_sdk "$APPEX/Contents/MacOS/JustArcQuickLook"
drop_build_rpaths "$APPEX/Contents/MacOS/JustArcQuickLook"
cp "$ROOT/Sources/JustArcQuickLook/Resources/Info.plist" "$APPEX/Contents/Info.plist"
# An extension whose version differs from its app's is one macOS may decline to load.
for key in CFBundleShortVersionString CFBundleVersion; do
  /usr/libexec/PlistBuddy -c "Set :$key $(/usr/libexec/PlistBuddy -c "Print :$key" "$APP/Contents/Info.plist")" \
    "$APPEX/Contents/Info.plist"
done
# Its strings are the app's: the preview is drawn with the same words.
for lproj in "$ROOT/Sources/JustArc/Resources/"*.lproj; do
  [ -f "$lproj/Localizable.strings" ] || continue
  mkdir -p "$APPEX/Contents/Resources/$(basename "$lproj")"
  cp "$lproj/Localizable.strings" "$APPEX/Contents/Resources/$(basename "$lproj")/"
done

# Ad-hoc signing keeps Gatekeeper quiet locally; a real build signs with a Developer ID.
# vtool and install_name_tool above invalidated the linker's own signature, and on
# Apple silicon an unsigned binary is killed at launch, so a failure here is fatal.
#
# Signed from the inside out, and the app itself without --deep: that would sign the
# extension again without its entitlements, and an extension that is not sandboxed
# is never loaded.
codesign --force --sign - --timestamp=none "$APP/Contents/Frameworks/7z.so"
codesign --force --deep --sign - --timestamp=none "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --sign - --timestamp=none "$APPEX/Contents/Frameworks/7z.so"
codesign --force --sign - --timestamp=none \
  --entitlements "$ROOT/Sources/JustArcQuickLook/Resources/JustArcQuickLook.entitlements" "$APPEX"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"

echo "Built $APP"
