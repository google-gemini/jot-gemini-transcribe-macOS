#!/bin/bash
# Builds a Release .app and a DMG. Notarization runs only when credentials exist:
#   xcrun notarytool store-credentials gt-notary --apple-id … --team-id … --password …
# (Sparkle auto-updates are wired at public release, once the feed URL exists.)
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(grep -m1 'MARKETING_VERSION' project.yml | awk '{print $2}' | tr -d '"')
BUILD_DIR="build/release"
APP_NAME="Google Transcribe"

echo "▸ Generating project"
xcodegen generate

echo "▸ Building Release"
env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=all \
  xcodebuild -project GoogleTranscribe.xcodeproj \
    -scheme GoogleTranscribe \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR/dd" \
    -destination 'platform=macOS' \
    ENABLE_HARDENED_RUNTIME=YES \
    -quiet build

APP_PATH="$BUILD_DIR/dd/Build/Products/Release/$APP_NAME.app"
[ -d "$APP_PATH" ] || { echo "build product missing"; exit 1; }

if xcrun notarytool history --keychain-profile gt-notary >/dev/null 2>&1; then
  echo "▸ Notarizing"
  ditto -c -k --keepParent "$APP_PATH" "$BUILD_DIR/notarize.zip"
  xcrun notarytool submit "$BUILD_DIR/notarize.zip" --keychain-profile gt-notary --wait
  xcrun stapler staple "$APP_PATH"
  spctl -a -t exec -vv "$APP_PATH"
else
  echo "▸ Skipping notarization (no 'gt-notary' keychain profile)"
fi

echo "▸ Building DMG"
DMG="$BUILD_DIR/GoogleTranscribe-$VERSION.dmg"
rm -f "$DMG"
STAGING="$BUILD_DIR/dmg-staging"
rm -rf "$STAGING" && mkdir -p "$STAGING"
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG" -quiet
rm -rf "$STAGING"

echo "✓ $DMG"
