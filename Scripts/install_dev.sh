#!/bin/bash
#
# Build the development configuration and put it in /Applications as
# "Caliper Dev.app" — its own name, its own bundle identifier, its own icon and
# no update feed, so it can never be mistaken for, or take the place of, the
# release.
#
# The previous copy is deleted rather than copied over: `cp -R` onto an existing
# bundle merges directories, so the new app keeps whatever the build before it
# left behind, and a stale framework is a failure with no cause in the source.
#
# Derived data is pinned to build/dd. Xcode keys its own on the project's path,
# so a worktree — or a checkout that moves — leaves a second Caliper on the Mac
# that Spotlight and the Dock list beside this one.
#
# Usage: Scripts/install_dev.sh

set -euo pipefail
cd "$(dirname "$0")/.."

DERIVED="$PWD/build/dd"
NAME="Caliper Dev"
APP="$NAME.app"
BUILT="$DERIVED/Build/Products/Debug/$APP"
INSTALLED="/Applications/$APP"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

command -v xcodegen >/dev/null || {
    echo "xcodegen is not installed: brew install xcodegen" >&2
    exit 1
}

xcodegen generate
xcodebuild -project Caliper.xcodeproj -scheme Caliper -configuration Debug \
    -derivedDataPath "$DERIVED" build

[ -d "$BUILT" ] || {
    echo "the build produced no $APP at $BUILT" >&2
    exit 1
}

# Only if it is up: `tell application ... to quit` launches an app that is not
# running in order to deliver the event, and starting the copy about to be
# deleted is a strange way to replace it. `pkill -x` is safe on this name and
# only this name — "Caliper Dev" can only be a build from here, where a bare
# "Caliper" would also match the release the user is running.
if pgrep -x "$NAME" >/dev/null 2>&1; then
    osascript -e "tell application \"$NAME\" to quit" >/dev/null 2>&1 || true
    for _ in $(seq 1 20); do
        pgrep -x "$NAME" >/dev/null 2>&1 || break
        sleep 0.5
    done
    pkill -x "$NAME" 2>/dev/null || true
fi

rm -rf "$INSTALLED"
ditto "$BUILT" "$INSTALLED"
# Registered by hand so that the app is findable now rather than whenever
# LaunchServices next notices /Applications changed, and the build product is
# dropped in the same breath: Xcode registers it as part of every build, and two
# entries named "Caliper Dev" in Spotlight are one more than there is an app.
# -R descends into the bundle, where Sparkle's embedded Updater.app holds a
# record of its own.
#
# Neither is allowed to fail the install: lsregister has moved between macOS
# releases, and by this point the app is already in place.
"$LSREGISTER" -f "$INSTALLED" >/dev/null 2>&1 || true
"$LSREGISTER" -R -u "$BUILT" >/dev/null 2>&1 || true
open "$INSTALLED"

echo "✓ $INSTALLED"
