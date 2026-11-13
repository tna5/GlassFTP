#!/bin/bash
# Renders the Liquid Glass app icons and compiles one into Resources/AppIcon.icns.
#
#   scripts/make-icon.sh            # variant 1c (bold transfer arrows)
#   VARIANT=2 scripts/make-icon.sh  # 2 = folder, 3 = orb
#
# Without Xcode there is no asset catalog step, so the icons are drawn by
# scripts/IconRenderer.swift (Core Graphics + Core Image, Command Line Tools
# only). Every variant is also kept in Resources/IconVariants for comparison.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VARIANT="${VARIANT:-1c}"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

swift "$ROOT/scripts/IconRenderer.swift" "$WORK" >/dev/null

VARIANTS="$ROOT/Resources/IconVariants"
mkdir -p "$VARIANTS"

build_icns() {
	local source="$1" output="$2"
	local iconset="$WORK/$(basename "$output" .icns).iconset"
	mkdir -p "$iconset"
	for size in 16 32 128 256 512; do
		sips -z $size $size "$source" --out "$iconset/icon_${size}x${size}.png" >/dev/null
		sips -z $((size * 2)) $((size * 2)) "$source" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
	done
	iconutil -c icns "$iconset" -o "$output"
}

for png in "$WORK"/icon-*.png; do
	name="$(basename "$png" .png)"
	cp "$png" "$VARIANTS/$name.png"
	build_icns "$png" "$VARIANTS/$name.icns"
done

CHOSEN="$(ls "$VARIANTS"/icon-"$VARIANT"-*.icns | head -1)"
cp "$CHOSEN" "$ROOT/Resources/AppIcon.icns"
echo "built $ROOT/Resources/AppIcon.icns from $(basename "$CHOSEN")"
