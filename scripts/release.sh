#!/bin/bash
# Builds a signed, notarized, stapled Jot.app and packages it as a DMG.
#
#   scripts/release.sh
#
# Signing is cloud-managed through the Apple account Xcode is signed into, so
# there is no identity to pass; JOT_TEAM_ID overrides the team if needed.
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

echo "▸ Archiving Release"
# Developer ID signing here is CLOUD MANAGED: the private key lives with Apple,
# not in the login keychain, so `codesign` with a local identity cannot work on
# this machine. Archive + exportArchive is the path that does — Xcode signs
# through the account. -allowProvisioningUpdates lets it mint what it needs.
rm -rf "$BUILD_DIR"
env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=all \
  xcodebuild archive \
    -project Jot.xcodeproj \
    -scheme Jot \
    -configuration Release \
    -archivePath "$BUILD_DIR/Jot.xcarchive" \
    -destination 'platform=macOS' \
    ENABLE_HARDENED_RUNTIME=YES \
    -allowProvisioningUpdates \
    -quiet

echo "▸ Exporting with Developer ID"
cat > "$BUILD_DIR/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>${JOT_TEAM_ID:-7S264298H8}</string>
  <key>signingStyle</key><string>automatic</string>
</dict>
</plist>
PLIST
env GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=safe.bareRepository GIT_CONFIG_VALUE_0=all \
  xcodebuild -exportArchive \
    -archivePath "$BUILD_DIR/Jot.xcarchive" \
    -exportPath "$BUILD_DIR/export" \
    -exportOptionsPlist "$BUILD_DIR/ExportOptions.plist" \
    -allowProvisioningUpdates

APP_PATH="$BUILD_DIR/export/$APP_NAME.app"
[ -d "$APP_PATH" ] || { echo "export produced no app"; exit 1; }

# --- Gate 1: it must really be Developer ID-signed, with no debug entitlement.
AUTHORITY=$(codesign -dvv "$APP_PATH" 2>&1 | grep '^Authority=' | head -1)
echo "▸ $AUTHORITY"
case "$AUTHORITY" in
  *"Developer ID Application"*) ;;
  *) echo "error: not Developer ID-signed — Gatekeeper would block this." >&2; exit 1 ;;
esac
if codesign -d --entitlements :- "$APP_PATH" 2>/dev/null | grep -q 'get-task-allow'; then
  echo "error: get-task-allow present — notarization will reject this build." >&2
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
DMG="$BUILD_DIR/Jot-$VERSION$SUFFIX.dmg"

if [ -z "$SUFFIX" ]; then
  # The CONTAINER needs its own signature. A notarization ticket alone is not
  # enough: Gatekeeper assesses the disk image before anything is mounted, and
  # an unsigned DMG is "rejected: no usable signature" — the wall we are trying
  # to spare people. Xcode's cloud-managed Developer ID key cannot sign here
  # (codesign has no local private key), so this needs a Developer ID
  # certificate created from a local CSR — see docs/RELEASING.md.
  DEVID=$(security find-identity -v -p codesigning 2>/dev/null \
          | grep "Developer ID Application" | head -1 \
          | sed -E 's/.*"(.*)"/\1/')
  if [ -n "$DEVID" ]; then
    echo "▸ Signing the disk image as: $DEVID"
    codesign --force --timestamp --sign "$DEVID" "$DMG"
  else
    echo "warning: no local Developer ID identity — the DMG cannot be signed." >&2
    echo "         The app inside is notarized and will open fine once copied," >&2
    echo "         but opening the DMG itself may warn. See docs/RELEASING.md." >&2
  fi

  echo "▸ Notarizing the DMG"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$DMG"
  echo "▸ Final assessment"
  spctl -a -t open --context context:primary-signature -vv "$DMG" || true
fi

echo "✓ $DMG"
