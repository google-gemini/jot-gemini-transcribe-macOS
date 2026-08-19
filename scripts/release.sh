#!/bin/bash
# Builds a signed, notarized, stapled Jot.app and packages it as a DMG.
#
#   JOT_CODESIGN_IDENTITY="Developer ID Application: NAME (TEAMID)" scripts/release.sh
#
# Anything you hand to another person MUST be Developer ID-signed and notarized,
# or Gatekeeper refuses to open it (macOS 15+ removed the right-click-Open
# bypass). This script fails loudly rather than emitting a DMG that looks
# shippable and is not. See docs/RELEASING.md.
#
# For a local-only build (yours, this machine, never shared):
#   JOT_ALLOW_UNNOTARIZED=1 scripts/release.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION=$(grep -m1 'MARKETING_VERSION' project.yml | awk '{print $2}' | tr -d '"')
BUILD_DIR="build/release"
APP_NAME="Jot"
NOTARY_PROFILE="${JOT_NOTARY_PROFILE:-jot-notary}"

echo "▸ Generating project"
xcodegen generate

echo "▸ Building Release"
SIGN_ARGS=()
if [ -n "${JOT_CODESIGN_IDENTITY:-}" ]; then
  # Manual signing also stops Xcode injecting get-task-allow, which notarization
  # rejects outright.
  SIGN_ARGS=(CODE_SIGN_STYLE=Manual "CODE_SIGN_IDENTITY=$JOT_CODESIGN_IDENTITY"
             OTHER_CODE_SIGN_FLAGS="--timestamp --options=runtime")
fi
rm -rf "$BUILD_DIR"
env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=all \
  xcodebuild -project Jot.xcodeproj \
    -scheme Jot \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR/dd" \
    -destination 'platform=macOS' \
    ENABLE_HARDENED_RUNTIME=YES \
    "${SIGN_ARGS[@]}" \
    -quiet build

APP_PATH="$BUILD_DIR/dd/Build/Products/Release/$APP_NAME.app"
[ -d "$APP_PATH" ] || { echo "build product missing"; exit 1; }

# --- Gate 1: the signature must be a Developer ID one, with no debug entitlement.
IDENTITY_LINE=$(codesign -dvv "$APP_PATH" 2>&1 | grep '^Authority=' | head -1 || true)
echo "▸ Signed by: ${IDENTITY_LINE:-<unsigned>}"
if codesign -d --entitlements :- "$APP_PATH" 2>/dev/null | grep -q 'get-task-allow'; then
  echo "error: get-task-allow is present — notarization will reject this build." >&2
  echo "       Pass JOT_CODESIGN_IDENTITY so the build signs manually." >&2
  exit 1
fi

# --- Gate 2: notarize, or refuse to produce a shippable-looking artifact.
if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "▸ Notarizing (profile: $NOTARY_PROFILE)"
  ditto -c -k --keepParent "$APP_PATH" "$BUILD_DIR/notarize.zip"
  xcrun notarytool submit "$BUILD_DIR/notarize.zip" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP_PATH"
  echo "▸ Gatekeeper assessment"
  spctl -a -t exec -vv "$APP_PATH"
  SUFFIX=""
elif [ "${JOT_ALLOW_UNNOTARIZED:-0}" = "1" ]; then
  echo "▸ NOT notarized (JOT_ALLOW_UNNOTARIZED=1) — local use only"
  SUFFIX="-UNNOTARIZED-DO-NOT-SHARE"
else
  echo "error: no '$NOTARY_PROFILE' notarytool profile — refusing to build a DMG." >&2
  echo "       Anyone you send it to would hit a Gatekeeper wall." >&2
  echo "       Set one up (docs/RELEASING.md), or pass JOT_ALLOW_UNNOTARIZED=1" >&2
  echo "       for a build you will only run yourself." >&2
  exit 1
fi

echo "▸ Building DMG"
scripts/make-dmg.sh "$APP_PATH" "$BUILD_DIR/Jot-$VERSION$SUFFIX.dmg"

if [ -n "${JOT_CODESIGN_IDENTITY:-}" ] && [ -z "$SUFFIX" ]; then
  # Notarize the container too, so the download itself is trusted before it is
  # ever mounted.
  echo "▸ Notarizing the DMG"
  xcrun notarytool submit "$BUILD_DIR/Jot-$VERSION.dmg" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$BUILD_DIR/Jot-$VERSION.dmg"
  spctl -a -t open --context context:primary-signature -vv "$BUILD_DIR/Jot-$VERSION.dmg"
fi

echo "✓ $BUILD_DIR/Jot-$VERSION$SUFFIX.dmg"
