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
mkdir -p build
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
  build > build/xcodebuild.log 2>&1 || {
    echo "xcodebuild failed. Errors (full log: build/xcodebuild.log):"
    grep -E -B2 -A6 "error:" build/xcodebuild.log | head -200 || true
    echo "----- last 40 lines -----"
    tail -40 build/xcodebuild.log
    exit 65
  }
grep -E "warning: .*\.swift" build/xcodebuild.log | sort -u | head -20 || true

APP="build/release/Build/Products/Release-iphoneos/SyncDarkroom.app"
[[ -d "$APP" ]] || { echo "Build failed: $APP not found"; exit 1; }

mkdir -p build/ipa/Payload
cp -R "$APP" build/ipa/Payload/
(cd build/ipa && zip -qry ../SyncDarkroom.ipa Payload)
rm -rf build/ipa

echo "Built build/SyncDarkroom.ipa ($(du -h build/SyncDarkroom.ipa | cut -f1))"
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Info.plist" | sed 's/^/  version: /'
/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Info.plist" | sed 's/^/  build:   /'
