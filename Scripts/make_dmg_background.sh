#!/bin/bash
#
# Build assets/dmg/background.tiff, the backdrop of the disk image window.
#
# A TIFF holding both scales rather than two PNGs: Finder picks the
# representation that matches the display, and a 1× picture stretched onto a
# Retina screen is the one thing that makes a window look homemade.
# `tiffutil -cathidpicheck` is what pairs them, and it verifies that the second
# image really is twice the first rather than trusting the filenames.
#
# The result is committed, so a release needs neither Swift nor this script.
#
# Usage: Scripts/make_dmg_background.sh
set -euo pipefail

cd "$(dirname "$0")/.."

OUT_DIR="assets/dmg"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$OUT_DIR"
swift Scripts/make_dmg_background.swift "$WORK/background.png" 1
swift Scripts/make_dmg_background.swift "$WORK/background@2x.png" 2
tiffutil -cathidpicheck "$WORK/background.png" "$WORK/background@2x.png" \
    -out "$OUT_DIR/background.tiff"

echo "✓ $OUT_DIR/background.tiff"
