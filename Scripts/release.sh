#!/bin/bash
# Builds, signs, notarizes and packages JustArc for distribution.
#
#   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   NOTARY_PROFILE=justarc \
#   ./Scripts/release.sh 0.1.0
#
# The notary profile is created once with:
#   xcrun notarytool store-credentials justarc \
#     --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
#
# Without SIGN_IDENTITY the script still produces a disk image, signed ad-hoc, which
# is useful for local testing but will be refused by Gatekeeper on another Mac.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' \
  "$ROOT/Sources/JustArc/Resources/Info.plist")}"
APP="$ROOT/build/JustArc.app"
STAGING="$ROOT/build/dmg-staging"
DMG="$ROOT/build/JustArc-$VERSION.dmg"
IDENTITY="${SIGN_IDENTITY:--}"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

echo "==> Building release binary"
"$ROOT/Scripts/build-app.sh" release

echo "==> Stamping version $VERSION"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d%H%M)" "$APP/Contents/Info.plist"

echo "==> Signing with: $IDENTITY"
if [ "$IDENTITY" = "-" ]; then
  echo "    (ad-hoc; set SIGN_IDENTITY for a distributable build)"
  HARDENED=()
else
  HARDENED=(--options runtime --timestamp)
fi

# Nested code is signed before the bundle that contains it.
codesign --force --sign "$IDENTITY" ${HARDENED[@]+"${HARDENED[@]}"} "$APP/Contents/Helpers/7zz"
codesign --force --sign "$IDENTITY" ${HARDENED[@]+"${HARDENED[@]}"} \
  --entitlements "$ROOT/Sources/JustArc/Resources/JustArc.entitlements" \
  "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> Building disk image"
rm -rf "$STAGING" "$DMG"
mkdir -p "$STAGING"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create "$DMG" -srcfolder "$STAGING" -volname "JustArc $VERSION" \
  -fs HFS+ -format ULFO -ov -quiet
rm -rf "$STAGING"

if [ "$IDENTITY" != "-" ]; then
  codesign --force --sign "$IDENTITY" --timestamp "$DMG"
fi

if [ -n "${NOTARY_PROFILE:-}" ] && [ "$IDENTITY" != "-" ]; then
  echo "==> Notarizing (this waits for Apple)"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  echo "==> Stapling"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  spctl --assess --type open --context context:primary-signature -vv "$DMG"
else
  echo "==> Skipping notarization (set SIGN_IDENTITY and NOTARY_PROFILE to enable)"
fi

echo
echo "Built $DMG"
