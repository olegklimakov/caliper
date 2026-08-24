#!/bin/bash
#
# Prints the path to Sparkle's command-line tools (generate_keys,
# generate_appcast, sign_update).
#
# They ship inside the Sparkle SPM artifact, so the copy this prints is always
# the exact version project.yml pins — no second download to keep in sync.
# Resolving packages fetches them if they aren't there yet.
#
#   Scripts/sparkle_tools.sh                          # print the bin directory
#   "$(Scripts/sparkle_tools.sh)/generate_keys"       # create the signing keys
#
# Everything but the path itself goes to stderr, so the above stays usable.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)
DERIVED="$ROOT/build/dd"

find_bin() {
    # `|| true`: with pipefail, find losing the pipe to head is a failure that
    # would otherwise kill the script under set -e.
    { find "$DERIVED/SourcePackages/artifacts" -maxdepth 4 -type d -path "*Sparkle*" -name bin \
        2>/dev/null || true; } | head -1
}

BIN=$(find_bin)
if [ -z "$BIN" ]; then
    echo "==> Resolving Swift packages to fetch Sparkle's tools" >&2
    command -v xcodegen >/dev/null ||
        { echo "xcodegen not installed (brew install xcodegen)" >&2; exit 1; }
    xcodegen generate >&2
    xcodebuild -project Caliper.xcodeproj -scheme Caliper \
        -derivedDataPath "$DERIVED" -resolvePackageDependencies >&2
    BIN=$(find_bin)
fi

[ -n "$BIN" ] ||
    { echo "Could not find Sparkle's tools under $DERIVED/SourcePackages/artifacts" >&2; exit 1; }
echo "$BIN"
