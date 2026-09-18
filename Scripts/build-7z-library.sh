#!/bin/bash
# Builds 7z.so, 7-Zip's format library, from the source vendored in
# Sources/SevenZipBridge/7zip, as a universal binary at Vendor/7z.so.
#
# The bridge target compiles 7-Zip's client-side files itself; this builds the other
# half, the format handlers and codecs, which the app loads at run time.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/Sources/SevenZipBridge/7zip"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

# Build in a copy so object files never land in the source tree.
cp -R "$SOURCE" "$WORK/7zip"
cd "$WORK/7zip/CPP/7zip/Bundles/Format7zF"

# 7-Zip builds with -Weverything and treats warnings as errors, which breaks with
# every new compiler release. The code is compiled unchanged; only that policy is off.
WARNINGS=(CFLAGS_WARN="-Wno-poison-system-directories" CFLAGS_WARN_WALL="-w")
JOBS="$(sysctl -n hw.ncpu)"

echo "Building arm64…"
make -j"$JOBS" -f ../../cmpl_mac_arm64.mak "${WARNINGS[@]}" > "$WORK/arm64.log" 2>&1 \
  || { tail -20 "$WORK/arm64.log"; exit 1; }
echo "Building x86_64…"
make -j"$JOBS" -f ../../cmpl_mac_x64.mak "${WARNINGS[@]}" > "$WORK/x64.log" 2>&1 \
  || { tail -20 "$WORK/x64.log"; exit 1; }

mkdir -p "$ROOT/Vendor"
lipo -create b/m_arm64/7z.so b/m_x64/7z.so -output "$ROOT/Vendor/7z.so"

# Captured first: piping nm into grep -q under pipefail fails whenever grep exits
# early and nm is killed by the closed pipe.
SYMBOLS="$(nm -gU -arch arm64 "$ROOT/Vendor/7z.so")"
for symbol in CreateObject GetNumberOfFormats GetHandlerProperty2 GetIsArc; do
  grep -q " _$symbol\$" <<< "$SYMBOLS" || { echo "7z.so is missing $symbol" >&2; exit 1; }
done

file "$ROOT/Vendor/7z.so"
