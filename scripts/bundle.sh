#!/bin/bash
# Assembles GlassFTP.app from the SwiftPM build product.
# Needed because this project builds without Xcode (Command Line Tools only),
# so there is no build system to produce the bundle for us.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG="${CONFIG:-release}"
APP="$ROOT/build/GlassFTP.app"

BIN="$(swift build --package-path "$ROOT" -c "$CONFIG" --show-bin-path)/GlassFTP"
if [ ! -x "$BIN" ]; then
	echo "error: binary not found at $BIN — run 'make build' first" >&2
	exit 1
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN" "$APP/Contents/MacOS/GlassFTP"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
	cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature. Note: the signature changes on every rebuild, so macOS
# re-prompts for Keychain access after each build. "Always Allow" clears it
# until the next build; a real Developer ID identity would remove it entirely.
codesign --force --sign - --timestamp=none "$APP" 2>&1 | sed 's/^/  codesign: /'

echo "built $APP"
