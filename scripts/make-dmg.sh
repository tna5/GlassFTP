#!/bin/bash
# Builds dist/GlassFTP-<version>.dmg: the app next to an Applications alias,
# over a background telling you to drag one onto the other.
# Expects build/GlassFTP.app (make bundle).
#
# The window layout is set through Finder with AppleScript, which needs
# Automation permission for Finder the first time. Without it the image is
# still built, just with Finder's default layout.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT/build/GlassFTP.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$ROOT/Resources/Info.plist")"
VOLUME="GlassFTP"
OUT="$ROOT/dist/GlassFTP-$VERSION.dmg"
WORK="$(mktemp -d)"
MOUNT=""
cleanup() {
	[ -n "$MOUNT" ] && hdiutil detach "$MOUNT" -quiet -force 2>/dev/null || true
	rm -rf "$WORK"
}
trap cleanup EXIT

[ -d "$APP" ] || { echo "error: $APP not found — run 'make bundle' first" >&2; exit 1; }
[ -d "/Volumes/$VOLUME" ] && { echo "error: /Volumes/$VOLUME is already mounted — eject it first" >&2; exit 1; }
mkdir -p "$ROOT/dist" "$WORK/stage/.background"

ditto "$APP" "$WORK/stage/GlassFTP.app"
ln -s /Applications "$WORK/stage/Applications"

# Background at 1x and 2x, combined so Retina screens get the sharp one.
swift "$ROOT/scripts/DMGBackground.swift" "$WORK/bg.png" 1
swift "$ROOT/scripts/DMGBackground.swift" "$WORK/bg@2x.png" 2
tiffutil -cathidpicheck "$WORK/bg.png" "$WORK/bg@2x.png" -out "$WORK/stage/.background/background.tiff" >/dev/null 2>&1

# Writable image first, so Finder can store the window layout in it.
hdiutil create -quiet -srcfolder "$WORK/stage" -volname "$VOLUME" -fs HFS+ \
	-format UDRW -size 200m "$WORK/rw.dmg"
MOUNT="$(hdiutil attach "$WORK/rw.dmg" -readwrite -noverify -noautoopen | awk -F'\t' '/\/Volumes\// {print $NF}')"

if ! osascript <<APPLESCRIPT
tell application "Finder"
	tell disk "$VOLUME"
		open
		set current view of container window to icon view
		set toolbar visible of container window to false
		set statusbar visible of container window to false
		set the bounds of container window to {200, 120, 860, 540}
		set viewOptions to the icon view options of container window
		set arrangement of viewOptions to not arranged
		set icon size of viewOptions to 128
		set text size of viewOptions to 13
		set background picture of viewOptions to file ".background:background.tiff"
		set position of item "GlassFTP.app" of container window to {180, 210}
		set position of item "Applications" of container window to {480, 210}
		close
		open
		update without registering applications
		delay 1
		close
	end tell
end tell
APPLESCRIPT
then
	echo "warning: could not lay out the window (Finder automation denied?); using defaults" >&2
fi

# Volume icon. After Finder has been through the window, which otherwise
# drops it.
cp "$ROOT/Resources/AppIcon.icns" "$MOUNT/.VolumeIcon.icns"
SetFile -a C "$MOUNT"

sync
hdiutil detach "$MOUNT" -quiet
MOUNT=""

rm -f "$OUT"
hdiutil convert -quiet "$WORK/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$OUT"
shasum -a 256 "$OUT"
