#!/bin/bash
#
# Build assets/icon/AppIcon.icns from the generated artwork.
# The artwork is the render as it comes out of the image model; make_icon.swift
# puts it on Apple's icon grid and clips it to the system shape, and iconutil
# packs the size ladder. The .icns is committed, so a build needs neither step.
#
# Usage: Scripts/make_icons.sh
set -euo pipefail

cd "$(dirname "$0")/.."

SRC="assets/caliper-app-icon-v2.png"
OUT_DIR="assets/icon"
MASTER="$OUT_DIR/icon-1024.png"
ICONSET="$OUT_DIR/AppIcon.iconset"

mkdir -p "$OUT_DIR"
swift Scripts/make_icon.swift "$SRC" "$MASTER"

rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    retina=$((size * 2))
    sips -s format png -Z "$size" "$MASTER" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -s format png -Z "$retina" "$MASTER" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET" -o "$OUT_DIR/AppIcon.icns"
rm -rf "$ICONSET"
echo "✓ $OUT_DIR/AppIcon.icns"
