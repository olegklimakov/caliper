#!/bin/bash
#
# Archives, signs, notarizes, staples and packages Caliper for distribution.
#
# Not run as part of any build: it uploads the app to Apple and needs
# credentials only the developer has. Set them up once with
#
#   xcrun notarytool store-credentials caliper-notary \
#       --apple-id <apple id> --team-id GCCNH99PN6 --password <app-specific password>
#
# and this script uses the stored profile rather than ever seeing the password.
#
# Not yet run end to end. Developer ID signing, the hardened runtime flag and
# the app group container are all verified locally, but an archive of a target
# that declares an app group may want a provisioning profile — if
# `xcodebuild archive` complains, add one to the target and to export.plist.
#
# Usage: Scripts/notarize.sh [version]

set -euo pipefail

VERSION="${1:-$(awk -F'"' '/MARKETING_VERSION/{print $2}' project.yml | head -1)}"
TEAM_ID="GCCNH99PN6"
IDENTITY="Developer ID Application: OLEG KLIMAKOV ($TEAM_ID)"
KEYCHAIN_PROFILE="caliper-notary"
BUILD_DIR="build"
ARCHIVE="$BUILD_DIR/Caliper.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
DMG="$BUILD_DIR/Caliper-$VERSION.dmg"

step() { printf "\n==> %s\n" "$1"; }

step "checking prerequisites"
security find-identity -v -p codesigning | grep -q "$TEAM_ID" ||
    { echo "no Developer ID certificate for team $TEAM_ID" >&2; exit 1; }
xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" >/dev/null 2>&1 ||
    { echo "no stored credentials — see the header of this script" >&2; exit 1; }

step "generating project"
xcodegen generate

step "archiving"
rm -rf "$ARCHIVE" "$EXPORT_DIR"
xcodebuild archive \
    -project Caliper.xcodeproj \
    -scheme Caliper \
    -configuration Release \
    -archivePath "$ARCHIVE" \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY="$IDENTITY" \
    DEVELOPMENT_TEAM="$TEAM_ID" \
    OTHER_CODE_SIGN_FLAGS="--timestamp"

step "exporting"
cat >"$BUILD_DIR/export.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key><string>developer-id</string>
    <key>teamID</key><string>$TEAM_ID</string>
    <key>signingStyle</key><string>manual</string>
</dict>
</plist>
PLIST
xcodebuild -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$BUILD_DIR/export.plist"

APP="$EXPORT_DIR/Caliper.app"

step "verifying the signature before submitting"
codesign --verify --deep --strict --verbose=2 "$APP"
# Hardened runtime is what notarization requires and what ad-hoc signing
# silently drops, so it is checked rather than assumed.
codesign -d --verbose=2 "$APP" 2>&1 | grep -q "flags=.*runtime" ||
    { echo "hardened runtime is not enabled" >&2; exit 1; }

# The app is notarized and stapled first, then packaged. Stapling only the disk
# image leaves the app itself without a ticket the moment it is dragged to
# /Applications, and it then needs the network to launch — which is exactly the
# clean-machine case PRD §6 asks about.
step "notarizing the app (this uploads it to Apple)"
APP_ZIP="$BUILD_DIR/Caliper.zip"
ditto -c -k --keepParent "$APP" "$APP_ZIP"
xcrun notarytool submit "$APP_ZIP" --keychain-profile "$KEYCHAIN_PROFILE" --wait

step "stapling the app"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

step "packaging"
rm -f "$DMG"
hdiutil create -volname "Caliper" -srcfolder "$APP" -ov -format UDZO "$DMG"

step "notarizing the disk image"
xcrun notarytool submit "$DMG" --keychain-profile "$KEYCHAIN_PROFILE" --wait

step "stapling the disk image"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

step "checking it the way a clean machine will"
spctl --assess --type execute -v "$APP"
spctl --assess --type open --context context:primary-signature -v "$DMG"

echo
echo "ready: $DMG"
echo "verify on a machine that has never seen this app before opening it here —"
echo "Gatekeeper caches a verdict per app, and this one has been run locally."
