#!/usr/bin/env bash
# Builds FlightKit.app and packages it into a drag-to-install .dmg.
# Usage: scripts/build-dmg.sh [version]
set -euo pipefail

cd "$(dirname "$0")/.."

VERSION="${1:-dev}"
DIST="$(pwd)/dist"
DMG="$DIST/FlightKit-$VERSION.dmg"
STAGE="$(mktemp -d)/FlightKit"

scripts/build-app.sh Release

mkdir -p "$STAGE"
cp -R "$DIST/FlightKit.app" "$STAGE/FlightKit.app"
ln -s /Applications "$STAGE/Applications"

rm -f "$DMG"
hdiutil create \
  -volname "FlightKit" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  "$DMG"

rm -rf "$STAGE"
echo "✓ $DMG"
shasum -a 256 "$DMG"
