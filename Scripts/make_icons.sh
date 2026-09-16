#!/bin/bash
#
# Build assets/icon/AppIcon.icns and assets/icon/AppIcon-Dev.icns from the
# generated artwork. The artwork is the render as it comes out of the image
# model; make_icon.swift puts it on Apple's icon grid, clips it to the system
# shape and — for the development build — stamps its badge, and iconutil packs
# the size ladder. Both .icns are committed, so a build needs neither step.
#
# Usage: Scripts/make_icons.sh
set -euo pipefail

cd "$(dirname "$0")/.."

SRC="assets/caliper-app-icon-v2.png"
OUT_DIR="assets/icon"

mkdir -p "$OUT_DIR"

# <master png> <icns name>
pack() {
    local master="$1" name="$2"
    local iconset="$OUT_DIR/$name.iconset"
    rm -rf "$iconset"
    mkdir -p "$iconset"
    for size in 16 32 128 256 512; do
        retina=$((size * 2))
        sips -s format png -Z "$size" "$master" --out "$iconset/icon_${size}x${size}.png" >/dev/null
        sips -s format png -Z "$retina" "$master" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
    done
    iconutil -c icns "$iconset" -o "$OUT_DIR/$name.icns"
    rm -rf "$iconset"
    echo "✓ $OUT_DIR/$name.icns"
}

swift Scripts/make_icon.swift "$SRC" "$OUT_DIR/icon-1024.png"
swift Scripts/make_icon.swift "$SRC" "$OUT_DIR/icon-dev-1024.png" --dev

pack "$OUT_DIR/icon-1024.png" AppIcon
pack "$OUT_DIR/icon-dev-1024.png" AppIcon-Dev
