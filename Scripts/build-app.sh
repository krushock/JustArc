#!/bin/bash
# Builds JustArc.app. Xcode's toolchain is used via DEVELOPER_DIR so no
# `sudo xcode-select` is needed when only the Command Line Tools are active.
#
#   Scripts/build-app.sh [debug|release] [--app-store]
#
# --app-store builds the Mac App Store edition into build/AppStore: the same code
# compiled with APP_STORE defined, sandboxed, without Sparkle and without the RAR
# download. Sources/JustArcCore/Support/Distribution.swift says what differs.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG=debug
APP_STORE=0
for arg in "$@"; do
  case "$arg" in
    --app-store) APP_STORE=1 ;;
    debug|release) CONFIG="$arg" ;;
    *) echo "usage: $0 [debug|release] [--app-store]" >&2; exit 2 ;;
  esac
done

APP="$ROOT/build/JustArc.app"
FLAGS=()
if [ "$APP_STORE" = 1 ]; then
  APP="$ROOT/build/AppStore/JustArc.app"
  # Sparkle is still a package dependency, so the linker is told to drop libraries
  # nothing uses; with its code compiled out, that is Sparkle.
  FLAGS=(-Xswiftc -DAPP_STORE -Xlinker -dead_strip_dylibs)
fi

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# A release runs on both Apple silicon and Intel, as the bundled 7z.so and Sparkle
# already do. A debug build is for this Mac only, and builds in half the time.
ARCHS=()
if [ "$CONFIG" = "release" ]; then
  ARCHS=(--arch arm64 --arch x86_64)
fi

echo "Building JustArc ($CONFIG$([ "$APP_STORE" = 1 ] && echo ", App Store edition"))…"
cd "$ROOT"
for product in JustArc JustArcQuickLook; do
  swift build --configuration "$CONFIG" --product "$product" ${ARCHS[@]+"${ARCHS[@]}"} ${FLAGS[@]+"${FLAGS[@]}"}
done

BIN="$(swift build --configuration "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"} ${FLAGS[@]+"${FLAGS[@]}"} --show-bin-path)"

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
# Every build gets a build number of its own. macOS keeps what it has learnt about
# an app, its document icons among them, until the version changes, so a rebuild
# under the same number can go on showing the old ones.
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d%H%M)" "$APP/Contents/Info.plist"
# 7-Zip's format library, loaded in process. It is not a framework, but Frameworks
# is where the hardened runtime expects code the app loads.
mkdir -p "$APP/Contents/Frameworks"
cp "$ROOT/Vendor/7z.so" "$APP/Contents/Frameworks/7z.so"
cp "$ROOT/Vendor/7zz-License.txt" "$APP/Contents/Resources/7-Zip-License.txt"
# JustArc's own licence, which Help ▸ Acknowledgements opens with the others.
cp "$ROOT/LICENSE" "$APP/Contents/Resources/License.txt"
# The bridge to 7-Zip, with the 7-Zip sources it is compiled from, is a library of
# its own, so that JustArc's executables contain nothing of 7-Zip's: see
# Packages/SevenZipBridge. The executables find it through this rpath.
cp "$BIN/libSevenZipBridge.dylib" "$APP/Contents/Frameworks/libSevenZipBridge.dylib"
drop_build_rpaths "$APP/Contents/Frameworks/libSevenZipBridge.dylib"
if ! otool -l "$APP/Contents/MacOS/JustArc" | grep -q "@executable_path/../Frameworks"; then
  install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/JustArc"
fi
cp "$ROOT/Sources/JustArc/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Localizations. Each .lproj folder is copied as-is next to the other resources.
for lproj in "$ROOT/Sources/JustArc/Resources/"*.lproj; do
  [ -d "$lproj" ] || continue
  cp -R "$lproj" "$APP/Contents/Resources/"
done
printf 'APPL????' > "$APP/Contents/PkgInfo"

SPARKLE="$ROOT/.build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [ "$APP_STORE" = 1 ]; then
  # The App Store updates its apps itself; an app that carries an updater of its
  # own is turned away. This one must not even link it.
  if otool -L "$APP/Contents/MacOS/JustArc" | grep -q Sparkle; then
    echo "error: the App Store build still links Sparkle" >&2
    exit 1
  fi
  drop_build_rpaths "$APP/Contents/MacOS/JustArc"
  # Its Info.plist says nothing of an updater, and does not offer to open disk
  # images, which it cannot mount.
  python3 - "$APP/Contents/Info.plist" <<'PY'
import plistlib, sys
path = sys.argv[1]
with open(path, 'rb') as f:
    info = plistlib.load(f)
for key in [k for k in info if k.startswith('SU')]:
    del info[key]
info['NSHumanReadableCopyright'] = 'Copyright © 2026 KruShock. Free software under the GNU GPL v3 or later. Compression by 7-Zip, under the GNU LGPL.'
disk_images = {'public.disk-image', 'com.apple.disk-image-udif'}
for group in info.get('CFBundleDocumentTypes', []) + info.get('NSServices', []):
    for key in ('LSItemContentTypes', 'NSSendFileTypes'):
        if key in group:
            group[key] = [t for t in group[key] if t not in disk_images]
with open(path, 'wb') as f:
    plistlib.dump(info, f)
PY
elif [ -d "$SPARKLE" ]; then
  # Sparkle ships as a universal XCFramework. Embed the macOS slice and give the
  # executable an rpath that points at it inside the bundle.
  rm -rf "$APP/Contents/Frameworks/Sparkle.framework"
  cp -R "$SPARKLE" "$APP/Contents/Frameworks/"
  if ! otool -l "$APP/Contents/MacOS/JustArc" | grep -q "@executable_path/../Frameworks"; then
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/JustArc" 2>/dev/null || true
  fi
  drop_build_rpaths "$APP/Contents/MacOS/JustArc"
  # Sparkle is MIT licensed, which asks that its notice go wherever it goes.
  cp "$ROOT/.build/artifacts/sparkle/Sparkle/LICENSE" "$APP/Contents/Resources/Sparkle-License.txt"
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
cp "$APP/Contents/Frameworks/libSevenZipBridge.dylib" "$APPEX/Contents/Frameworks/libSevenZipBridge.dylib"
cp "$BIN/JustArcQuickLook" "$APPEX/Contents/MacOS/JustArcQuickLook"
stamp_sdk "$APPEX/Contents/MacOS/JustArcQuickLook"
drop_build_rpaths "$APPEX/Contents/MacOS/JustArcQuickLook"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APPEX/Contents/MacOS/JustArcQuickLook"
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

# Ad-hoc signing keeps Gatekeeper quiet locally; a real build signs with a Developer ID,
# or for the App Store with an Apple Distribution identity and a provisioning profile.
# vtool and install_name_tool above invalidated the linker's own signature, and on
# Apple silicon an unsigned binary is killed at launch, so a failure here is fatal.
#
# Signed from the inside out, and the app itself without --deep: that would sign the
# extension again without its entitlements, and an extension that is not sandboxed
# is never loaded.
codesign --force --sign - --timestamp=none "$APP/Contents/Frameworks/7z.so"
codesign --force --sign - --timestamp=none "$APP/Contents/Frameworks/libSevenZipBridge.dylib"
if [ "$APP_STORE" = 0 ]; then
  codesign --force --deep --sign - --timestamp=none "$APP/Contents/Frameworks/Sparkle.framework"
fi
codesign --force --sign - --timestamp=none "$APPEX/Contents/Frameworks/7z.so"
codesign --force --sign - --timestamp=none "$APPEX/Contents/Frameworks/libSevenZipBridge.dylib"
codesign --force --sign - --timestamp=none \
  --entitlements "$ROOT/Sources/JustArcQuickLook/Resources/JustArcQuickLook.entitlements" "$APPEX"
if [ "$APP_STORE" = 1 ]; then
  # Sandboxed, as the store requires.
  codesign --force --sign - --timestamp=none \
    --entitlements "$ROOT/Sources/JustArc/Resources/JustArc-AppStore.entitlements" "$APP"
else
  codesign --force --sign - --timestamp=none "$APP"
fi
codesign --verify --deep --strict "$APP"

echo "Built $APP"
