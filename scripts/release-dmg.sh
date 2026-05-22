#!/usr/bin/env bash
# Build, Developer-ID sign, notarize, staple, and package FlightKit into a .dmg.
# Used by CI for tagged releases. Requires a Developer ID Application identity in
# the keychain and an App Store Connect API key for notarytool.
#
# Required environment:
#   SIGNING_IDENTITY  e.g. "Developer ID Application: Jane Doe (ABCDE12345)"
#   ASC_KEY_PATH      path to the App Store Connect API .p8
#   ASC_KEY_ID        API Key ID
#   ASC_ISSUER_ID     API Issuer ID
# Usage: scripts/release-dmg.sh <version>
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: release-dmg.sh <version>}"
: "${SIGNING_IDENTITY:?set SIGNING_IDENTITY}"
: "${ASC_KEY_PATH:?set ASC_KEY_PATH}"
: "${ASC_KEY_ID:?set ASC_KEY_ID}"
: "${ASC_ISSUER_ID:?set ASC_ISSUER_ID}"

DIST="$(pwd)/dist"
APP="$DIST/FlightKit.app"
DMG="$DIST/FlightKit-$VERSION.dmg"
STAGE="$(mktemp -d)/FlightKit"

# 1. Build (unsigned), then re-sign with Developer ID + hardened runtime + timestamp.
scripts/build-app.sh Release
codesign --force --options runtime --timestamp \
  --entitlements FlightKit/FlightKit.entitlements \
  --sign "$SIGNING_IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

# 2. Notarize the app and staple the ticket (so it launches offline too).
ditto -c -k --keepParent "$APP" "$DIST/FlightKit.zip"
xcrun notarytool submit "$DIST/FlightKit.zip" \
  --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait
xcrun stapler staple "$APP"
rm -f "$DIST/FlightKit.zip"

# 3. Package the stapled app into a drag-to-install DMG.
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/FlightKit.app"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "FlightKit" -srcfolder "$STAGE" -ov -format UDZO "$DMG"
rm -rf "$STAGE"

# 4. Notarize + staple the DMG itself (clears the "downloaded" warning on the DMG).
xcrun notarytool submit "$DMG" \
  --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait
xcrun stapler staple "$DMG"

echo "✓ $DMG"
shasum -a 256 "$DMG"
