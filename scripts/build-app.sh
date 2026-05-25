#!/usr/bin/env bash
# Builds FlightKit.app (unsigned, ad-hoc) into dist/.
# Usage: scripts/build-app.sh [Debug|Release] [marketing-version]
# When a version is given it is stamped into the bundle (CFBundleShortVersionString
# / CFBundleVersion) — otherwise the project's default (1.0) is used. Sparkle and
# the appcast rely on the shipped bundle carrying the real release version.
set -euo pipefail

cd "$(dirname "$0")/.."

CONFIG="${1:-Release}"
VERSION="${2:-}"
DERIVED="$(pwd)/.build"
DIST="$(pwd)/dist"

VERSION_ARGS=()
if [[ -n "$VERSION" ]]; then
  VERSION_ARGS=("MARKETING_VERSION=$VERSION" "CURRENT_PROJECT_VERSION=$VERSION")
fi

echo "▶ Generating Xcode project…"
python3 generate_pbxproj.py

echo "▶ Building FlightKit ($CONFIG${VERSION:+ v$VERSION})…"
xcodebuild \
  -project FlightKit.xcodeproj \
  -scheme FlightKit \
  -configuration "$CONFIG" \
  -destination 'platform=macOS' \
  -derivedDataPath "$DERIVED" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGNING_ALLOWED=NO \
  "${VERSION_ARGS[@]}" \
  build | tail -5

BUILT="$DERIVED/Build/Products/$CONFIG/FlightKit.app"
[[ -d "$BUILT" ]] || { echo "✗ Build artifact not found at $BUILT"; exit 1; }

mkdir -p "$DIST"
rm -rf "$DIST/FlightKit.app"
cp -R "$BUILT" "$DIST/FlightKit.app"
echo "✓ $DIST/FlightKit.app"
