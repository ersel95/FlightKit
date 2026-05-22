#!/usr/bin/env bash
# Builds FlightKit.app (unsigned, ad-hoc) into dist/.
# Usage: scripts/build-app.sh [Debug|Release]
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-Release}"
DERIVED="$(pwd)/.build"
DIST="$(pwd)/dist"

echo "▶ Generating Xcode project…"
python3 generate_pbxproj.py

echo "▶ Building FlightKit ($CONFIG)…"
xcodebuild \
  -project FlightKit.xcodeproj \
  -scheme FlightKit \
  -configuration "$CONFIG" \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  build | tail -5

BUILT="$DERIVED/Build/Products/$CONFIG/FlightKit.app"
[[ -d "$BUILT" ]] || { echo "✗ Build artifact not found at $BUILT"; exit 1; }

mkdir -p "$DIST"
rm -rf "$DIST/FlightKit.app"
cp -R "$BUILT" "$DIST/FlightKit.app"
echo "✓ $DIST/FlightKit.app"
