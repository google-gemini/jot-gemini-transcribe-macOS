#!/bin/bash
# Packages a built Jot.app into a drag-to-install DMG with custom art.
#
#   scripts/make-dmg.sh <path-to-Jot.app> [output.dmg]
#
# Layout is set through Finder (AppleScript), which is how every Mac installer
# DMG is made. The first run may ask for permission to control Finder.
set -euo pipefail
cd "$(dirname "$0")/.."

APP_PATH="${1:?usage: make-dmg.sh <Jot.app> [output.dmg]}"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP_PATH/Contents/Info.plist")
OUT_DMG="${2:-build/Jot-$VERSION.dmg}"
VOLUME_NAME="Jot"
STAGING="build/dmg-staging"
RW_DMG="build/jot-rw.dmg"

# Icon coordinates MUST match scripts/make-dmg-background.swift — but Finder's
# origin is TOP-left while the art is drawn bottom-left, so Y is flipped here.
WIN_W=700; WIN_H=460
APP_X=190;  APP_Y=$((WIN_H - 215))
LINK_X=510; LINK_Y=$((WIN_H - 215))
# Finder's window bounds include the title bar; the CONTENT must equal the art.
TITLEBAR=28

echo "▸ Rendering background art"
swift scripts/make-dmg-background.swift >/dev/null
# A lone 1x PNG gets upscaled on Retina and looks pixelated. A multi-rep TIFF
# carries both scales in one file, which is what Finder actually honours.
tiffutil -cathidpicheck build/dmg-background.png build/dmg-background@2x.png \
  -out build/dmg-background.tiff >/dev/null

echo "▸ Staging"
rm -rf "$STAGING" "$RW_DMG" "$OUT_DMG"
mkdir -p "$STAGING/.background"
cp -R "$APP_PATH" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
cp build/dmg-background.tiff "$STAGING/.background/background.tiff"

echo "▸ Creating read/write image"
hdiutil create -srcfolder "$STAGING" -volname "$VOLUME_NAME" -fs HFS+ \
  -format UDRW -ov "$RW_DMG" >/dev/null

MOUNT_DIR="/Volumes/$VOLUME_NAME"
hdiutil attach "$RW_DMG" -noautoopen -quiet
# Give Finder a moment to see the volume before scripting it.
for _ in $(seq 1 20); do [ -d "$MOUNT_DIR" ] && break; sleep 0.25; done

echo "▸ Arranging the window"
osascript <<APPLESCRIPT || echo "  (Finder scripting unavailable — DMG still works, layout will be default)"
tell application "Finder"
  tell disk "$VOLUME_NAME"
    open
    set theWindow to container window
    set current view of theWindow to icon view
    set toolbar visible of theWindow to false
    set statusbar visible of theWindow to false
    set the bounds of theWindow to {200, 160, $((200 + WIN_W)), $((160 + WIN_H + TITLEBAR))}
    set viewOptions to the icon view options of theWindow
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to 96
    set text size of viewOptions to 12
    set background picture of viewOptions to file ".background:background.tiff"
    set position of item "Jot.app" of theWindow to {$APP_X, $APP_Y}
    set position of item "Applications" of theWindow to {$LINK_X, $LINK_Y}
    -- Anything not part of the pitch goes off-canvas (only reachable when the
    -- user has "show hidden files" on, but then it would sit on the artwork).
    try
      set position of item ".background" of theWindow to {$((WIN_W + 260)), 240}
    end try
    try
      set position of item ".fseventsd" of theWindow to {$((WIN_W + 260)), 360}
    end try
    -- Bounds LAST: view options can resize the window, and the content area must
    -- end up exactly the size of the background art.
    set the bounds of theWindow to {200, 160, $((200 + WIN_W)), $((160 + WIN_H + TITLEBAR))}
    update without registering applications
    delay 2
    close
  end tell
end tell
APPLESCRIPT

# No volume-icon file: every technique for it (.VolumeIcon.icns, an Icon\r
# resource fork) leaves a stray item visible to anyone with "show hidden files"
# on, and a generic disk icon in the title bar is normal for a DMG. The window
# art is what sells the install.
SetFile -a C "$MOUNT_DIR" 2>/dev/null || true
# Keep the plumbing out of sight even for people who show hidden files.
chflags hidden "$MOUNT_DIR/.background" 2>/dev/null || true
sync
hdiutil detach "$MOUNT_DIR" -quiet || hdiutil detach "$MOUNT_DIR" -force -quiet

echo "▸ Compressing"
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$OUT_DMG" >/dev/null
rm -f "$RW_DMG"
rm -rf "$STAGING"

# The container is signed by notarizing + stapling it in scripts/release.sh;
# there is no local Developer ID key to codesign with (cloud-managed signing).

echo "✓ $OUT_DMG ($(du -h "$OUT_DMG" | cut -f1))"
