#!/usr/bin/env bash
# Builds an unsigned SyncDarkroom.ipa for AltStore (AltStore re-signs it on the device).
#
# Usage: scripts/build_ipa.sh [version] [build-number]
#   version       marketing version, e.g. 0.2.0 (default: value in project.yml)
#   build-number  CFBundleVersion, e.g. 7 (default: value in project.yml)
# Output: build/SyncDarkroom.ipa
set -euo pipefail

cd "$(dirname "$0")/.."
VERSION="${1:-}"
BUILD="${2:-}"

command -v xcodegen >/dev/null || { echo "xcodegen is required (brew install xcodegen)"; exit 1; }
xcodegen generate --quiet

EXTRA=()
[[ -n "$VERSION" ]] && EXTRA+=("MARKETING_VERSION=$VERSION")
[[ -n "$BUILD" ]] && EXTRA+=("CURRENT_PROJECT_VERSION=$BUILD")

rm -rf build/ipa build/SyncDarkroom.ipa
xcodebuild \
  -project SyncDarkroom.xcodeproj \
  -scheme SyncDarkroom \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -derivedDataPath build/release \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY="" \
  ${EXTRA[@]+"${EXTRA[@]}"} \
  build | (command -v xcpretty >/dev/null && xcpretty || grep -E "error:|warning: .*\.swift|BUILD (SUCCEEDED|FAILED)")

APP="build/release/Build/Products/Release-iphoneos/SyncDarkroom.app"
[[ -d "$APP" ]] || { echo "Build failed: $APP not found"; exit 1; }

mkdir -p build/ipa/Payload
cp -R "$APP" build/ipa/Payload/
(cd build/ipa && zip -qry ../SyncDarkroom.ipa Payload)
rm -rf build/ipa

echo "Built build/SyncDarkroom.ipa ($(du -h build/SyncDarkroom.ipa | cut -f1))"
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Info.plist" | sed 's/^/  version: /'
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Info.plist" | sed 's/^/  build:   /'
