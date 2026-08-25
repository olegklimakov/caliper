#!/bin/bash
#
# Builds, signs, notarizes and publishes a release of Caliper: the disk image a
# person downloads, the archive Sparkle installs, and the appcast that tells an
# installed copy either exists.
#
# Not run as part of any build: it uploads the app to Apple and needs
# credentials only the developer has. Set them up once with
#
#   xcrun notarytool store-credentials caliper-notary \
#       --apple-id <apple id> --team-id GCCNH99PN6 --password <app-specific password>
#
# and this script uses the stored profile rather than ever seeing the password.
#
# Updates are signed with the EdDSA key in the login Keychain, created once via
# `"$(Scripts/sparkle_tools.sh)/generate_keys"`. Both the release and the feed
# go to the *public* repository: this one is private, and Sparkle cannot
# download an asset it would have to log in for.
#
# Nothing is uploaded unless you ask for it:
#
#   PUBLISH=1 Scripts/release.sh
#
# publishes the GitHub release the feed URL resolves to. Without PUBLISH the
# script stops after building and prints the command it would have run.
#
# Release notes: put them in release-notes/<version>.html — shown inside
# Sparkle's window — and release-notes/<version>.md for the GitHub release body.
# The two are not interchangeable: GitHub strips tags it does not allow and
# leaves what was inside them as prose, so a stylesheet arrives as text.
#
# Usage: [PUBLISH=1] Scripts/release.sh

set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)

VERSION=$(awk -F'"' '/MARKETING_VERSION/{print $2; exit}' project.yml)
[ -n "$VERSION" ] || { echo "no MARKETING_VERSION in project.yml" >&2; exit 1; }
BUILD_NUMBER=$(awk -F'"' '/CURRENT_PROJECT_VERSION/{print $2; exit}' project.yml)
[ -n "$BUILD_NUMBER" ] || { echo "no CURRENT_PROJECT_VERSION in project.yml" >&2; exit 1; }

TEAM_ID="GCCNH99PN6"
IDENTITY="Developer ID Application: OLEG KLIMAKOV ($TEAM_ID)"
KEYCHAIN_PROFILE="caliper-notary"
REPO="olegklimakov/caliper"
TAG="v$VERSION"

BUILD_DIR="$ROOT/build"
ARCHIVE="$BUILD_DIR/Caliper.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
DIST="$ROOT/dist"
# What generate_appcast is pointed at. Only the archive Sparkle installs and its
# release notes may live here: the tool makes an item out of every archive it
# finds, and the disk image sitting beside the zip would be published as a
# second update to the same version.
FEED="$DIST/feed"
DMG="$DIST/Caliper-$VERSION.dmg"
ZIP="$FEED/Caliper-$VERSION.zip"
NOTES_HTML="$ROOT/release-notes/$VERSION.html"
NOTES_MD="$ROOT/release-notes/$VERSION.md"

step() { printf "\n==> %s\n" "$1"; }

# The bundles Sparkle ships inside its framework, innermost first — which is the
# order they must be signed in, since signing an outer bundle seals the hashes
# of everything inside it. Spelled out once: two copies in two orders is two
# answers to "what has to be signed".
nested_bundles() {
    local sparkle="$1"
    find "$sparkle/Versions/B/XPCServices" -maxdepth 1 -name "*.xpc" 2>/dev/null || true
    echo "$sparkle/Versions/B/Updater.app"
    echo "$sparkle/Versions/B/Autoupdate"
    echo "$sparkle/Versions/B"
}

# Sparkle's layout is Sparkle's to change. If it ever does, every path above
# stops existing, both loops below run zero times, and the checks report success
# having examined nothing — so the count is asserted rather than assumed.
NESTED_EXPECTED=5

# Every check below costs seconds; every one of them skipped costs a build and a
# round trip to Apple to be told the same thing.
step "checking prerequisites"

# Read into a variable rather than piped to `grep -q`, which exits on its first
# match and leaves `security` writing into a closed pipe — a failure `pipefail`
# would report as this check failing.
identities=$(security find-identity -v -p codesigning)
case $identities in
*"$TEAM_ID"*) ;;
*) echo "no Developer ID certificate for team $TEAM_ID" >&2; exit 1 ;;
esac
xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" >/dev/null 2>&1 ||
    { echo "no stored credentials — see the header of this script" >&2; exit 1; }

# An unauthenticated or offline `gh` answers every question below with "no",
# which is the answer that lets a release through. Establish once that its
# answers mean anything.
gh auth status >/dev/null 2>&1 ||
    { echo "gh is not authenticated — the guards below cannot be trusted" >&2; exit 1; }

if release_state=$(gh release view "$TAG" --repo "$REPO" --json tagName 2>&1); then
    echo "$REPO already has $TAG — bump MARKETING_VERSION and CURRENT_PROJECT_VERSION." >&2
    exit 1
elif ! grep -qi "release not found" <<<"$release_state"; then
    echo "could not check whether $TAG exists on $REPO:" >&2
    echo "$release_state" >&2
    exit 1
fi

# The public key in the app and the private key in the Keychain have to be two
# halves of one pair. An app carrying the public half of a *different* pair
# rejects every update it is ever offered — silently, and unfixably, because the
# fix would have to arrive through the channel that is broken.
SPARKLE_BIN=$(Scripts/sparkle_tools.sh)
BUNDLED_KEY=$(awk '/SUPublicEDKey:/{print $2; exit}' project.yml)
[ -n "$BUNDLED_KEY" ] ||
    { echo "SUPublicEDKey is missing from project.yml — updates could not be verified" >&2; exit 1; }
KEYCHAIN_KEY=$("$SPARKLE_BIN/generate_keys" -p 2>/dev/null) || {
    echo "no Sparkle private key in the Keychain — the appcast could not be signed." >&2
    echo "Create the pair once with \"$SPARKLE_BIN/generate_keys\"." >&2
    exit 1
}
if [ "$KEYCHAIN_KEY" != "$BUNDLED_KEY" ]; then
    echo "SUPublicEDKey does not match the signing key in the Keychain:" >&2
    echo "  project.yml: $BUNDLED_KEY" >&2
    echo "  Keychain:    $KEYCHAIN_KEY" >&2
    echo "Updates signed by this machine would be refused by the shipped app." >&2
    exit 1
fi

command -v create-dmg >/dev/null ||
    { echo "create-dmg not installed (brew install create-dmg)" >&2; exit 1; }
[ -f "$ROOT/assets/dmg/background.tiff" ] ||
    { echo "no disk image backdrop — run Scripts/make_dmg_background.sh" >&2; exit 1; }

step "generating project"
command -v xcodegen >/dev/null ||
    { echo "xcodegen not installed (brew install xcodegen)" >&2; exit 1; }
xcodegen generate

# Below the cheap guards and above the build: quick, and a failure here is worth
# hearing about before a notarization round trip.
step "running the tests"
(cd Packages/CaliperCore && swift test)
(cd Packages/CaliperHistory && swift test)

step "checking the version against what is already published"
rm -rf "$DIST"
mkdir -p "$FEED"
# Start from the published appcast so earlier items survive. Only a repository
# with no releases at all may skip this: any other failure would silently
# produce a feed that drops every version already out there.
if gh release view --repo "$REPO" --json tagName >/dev/null 2>&1; then
    gh release download --repo "$REPO" --pattern appcast.xml --dir "$FEED"
else
    echo "    (no published release yet — starting a new appcast)"
fi
if [ -f "$FEED/appcast.xml" ]; then
    # Sparkle offers an update by comparing CFBundleVersion, so a marketing bump
    # over a stale build number would ship an update nobody is ever told about.
    # One element per line first, so the number is read out of the element
    # generate_appcast writes rather than out of whatever else on the line
    # happens to contain the word "version".
    PUBLISHED=$(xmllint --format "$FEED/appcast.xml" |
        sed -n 's|.*<sparkle:version>\([0-9][0-9]*\)</sparkle:version>.*|\1|p' |
        sort -n | tail -1)
    # An appcast that parsed to nothing is a changed format, not an empty feed,
    # and a guard that reports success over zero rows is not a guard.
    [ -n "$PUBLISHED" ] ||
        { echo "read no <sparkle:version> out of the published appcast" >&2; exit 1; }
    if [ "$BUILD_NUMBER" -le "$PUBLISHED" ]; then
        echo "CURRENT_PROJECT_VERSION ($BUILD_NUMBER) is not above the published build ($PUBLISHED)." >&2
        echo "Sparkle compares that number — bump it in project.yml." >&2
        exit 1
    fi
fi

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
    ENABLE_HARDENED_RUNTIME=YES \
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
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"

# Sparkle ships four further bundles inside its framework — the updater app, its
# two XPC services and the Autoupdate tool — which arrive from the SPM artifact
# already signed, ad-hoc, by the Sparkle project. Notarization refuses a
# submission holding anything not signed with the same Developer ID.
#
# Re-signed innermost first, because signing an outer bundle seals the hashes of
# everything inside it, and the app's own signature is renewed afterwards over
# the framework it now contains.
#
# --preserve-metadata=entitlements: the installer XPC service carries
# entitlements of its own, and re-signing without them leaves an updater that
# cannot install anything.
step "re-signing Sparkle's nested bundles"
NESTED=$(nested_bundles "$SPARKLE")
NESTED_COUNT=$(grep -c . <<<"$NESTED" || true)
[ "$NESTED_COUNT" -eq "$NESTED_EXPECTED" ] || {
    echo "expected $NESTED_EXPECTED bundles inside Sparkle.framework, found $NESTED_COUNT:" >&2
    echo "$NESTED" >&2
    echo "Sparkle's layout has changed — the signing below would miss what it misses." >&2
    exit 1
}
while IFS= read -r nested; do
    [ -e "$nested" ] || { echo "no such bundle: $nested" >&2; exit 1; }
    codesign --force --sign "$IDENTITY" --timestamp --options=runtime \
        --preserve-metadata=entitlements "$nested"
done <<<"$NESTED"
codesign --force --sign "$IDENTITY" --timestamp --options=runtime \
    --entitlements App/Caliper.entitlements "$APP"

step "verifying the signature before submitting"
codesign --verify --deep --strict --verbose=2 "$APP"
# Every bundle in the submission has to carry this identity and the hardened
# runtime; either one missing is a rejection minutes from now instead of a
# failure here. Read into a variable rather than piped to `grep -q`, which exits
# on its first match and leaves codesign writing into a closed pipe — a failure
# `set -o pipefail` would report as the check itself failing.
CHECKED=0
while IFS= read -r nested; do
    [ -e "$nested" ] || { echo "no such bundle: $nested" >&2; exit 1; }
    description=$(codesign -dv --verbose=4 "$nested" 2>&1)
    case $description in
    *"flags="*"runtime"*) ;;
    *) echo "not signed with the hardened runtime: $nested" >&2; exit 1 ;;
    esac
    case $description in
    *"Authority=$IDENTITY"*) ;;
    *) echo "not signed with the release identity: $nested" >&2; exit 1 ;;
    esac
    CHECKED=$((CHECKED + 1))
done <<<"$APP
$NESTED"
echo "    $CHECKED bundles carry the release identity and the hardened runtime"
[ "$CHECKED" -eq "$((NESTED_EXPECTED + 1))" ] ||
    { echo "checked $CHECKED bundles, expected $((NESTED_EXPECTED + 1))" >&2; exit 1; }

# The key the *shipped bundle* carries, which is the only one that matters. The
# check at the top read project.yml so a mismatch fails in seconds rather than
# after a build; this one reads what XcodeGen actually wrote, and catches the
# plist wiring silently dropping the key — the same silent-and-unfixable failure
# by a different route.
SHIPPED_KEY=$(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" "$APP/Contents/Info.plist" 2>/dev/null) ||
    { echo "the built app carries no SUPublicEDKey — it could verify no update" >&2; exit 1; }
[ "$SHIPPED_KEY" = "$KEYCHAIN_KEY" ] || {
    echo "the built app's SUPublicEDKey is not the key this machine signs with:" >&2
    echo "  in the bundle: $SHIPPED_KEY" >&2
    echo "  in the Keychain: $KEYCHAIN_KEY" >&2
    exit 1
}

# The app is notarized and stapled first, then packaged. A ticket is issued
# against the exact bytes that were sent, so stapling only the disk image leaves
# the app itself without one the moment it is dragged to /Applications — and it
# then needs the network to launch, which is exactly the clean-machine case
# PRD §6 asks about.
step "notarizing the app (this uploads it to Apple)"
ditto -c -k --keepParent "$APP" "$BUILD_DIR/notarize.zip"
xcrun notarytool submit "$BUILD_DIR/notarize.zip" --keychain-profile "$KEYCHAIN_PROFILE" --wait

step "stapling the app"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

step "packaging"
# Zipped from the stapled app, so the copy Sparkle installs carries its ticket
# and opens offline. Into the feed directory, which holds nothing else.
ditto -c -k --keepParent "$APP" "$ZIP"

# The disk image is the first thing anyone sees of this app, and `hdiutil` on
# its own hands them a bare bundle in a bare folder — with no /Applications to
# drop it on, which is what every set of installation instructions ever written
# tells people to do. `create-dmg` sets the window's size, its backdrop, where
# the two icons sit and the alias itself; assets/dmg/background.tiff is drawn
# by Scripts/make_dmg_background.swift, which holds the same coordinates.
#
# From a folder holding nothing but the app: the export directory also has
# Xcode's plists and logs in it, and every one of them would arrive in the
# window beside the icon.
STAGE="$BUILD_DIR/dmg"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
create-dmg \
    --volname "Caliper" \
    --volicon "$ROOT/assets/icon/AppIcon.icns" \
    --background "$ROOT/assets/dmg/background.tiff" \
    --window-pos 200 120 \
    --window-size 660 420 \
    --icon-size 128 \
    --icon "Caliper.app" 165 188 \
    --app-drop-link 495 188 \
    --hide-extension "Caliper.app" \
    --no-internet-enable \
    "$DMG" "$STAGE"
codesign --force --sign "$IDENTITY" --timestamp "$DMG"

step "notarizing the disk image"
xcrun notarytool submit "$DMG" --keychain-profile "$KEYCHAIN_PROFILE" --wait

step "stapling the disk image"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

step "checking it the way a clean machine will"
spctl --assess --type execute -v "$APP"
spctl --assess --type open --context context:primary-signature -v "$DMG"

step "signing the appcast"
# generate_appcast picks release notes up by filename: Caliper-1.2.3.html next
# to Caliper-1.2.3.zip becomes that item's description.
if [ -f "$NOTES_HTML" ]; then
    cp "$NOTES_HTML" "$FEED/Caliper-$VERSION.html"
else
    echo "    (no release-notes/$VERSION.html — the update window will have nothing to read)"
fi
"$SPARKLE_BIN/generate_appcast" "$FEED" \
    --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
    --link "https://github.com/$REPO" \
    --maximum-versions 5

echo
echo "built: $DMG"
echo "       $ZIP"
echo "       $FEED/appcast.xml"

PUBLISH_ARGS=(release create "$TAG" "$DMG" "$ZIP" "$FEED/appcast.xml"
    --repo "$REPO" --title "Caliper $VERSION")
if [ -f "$NOTES_MD" ]; then
    PUBLISH_ARGS+=(--notes-file "$NOTES_MD")
else
    PUBLISH_ARGS+=(--generate-notes)
fi

if [ "${PUBLISH:-}" = "1" ]; then
    step "publishing $TAG"
    # Not a pre-release: the feed URL resolves through /releases/latest/, which
    # skips pre-releases and would leave everyone on the version before it.
    gh "${PUBLISH_ARGS[@]}"
    echo
    echo "published: https://github.com/$REPO/releases/tag/$TAG"
else
    echo
    echo "Not published. To publish, re-run with PUBLISH=1, or:"
    printf '  gh'
    printf ' %q' "${PUBLISH_ARGS[@]}"
    echo
fi

echo
echo "verify on a machine that has never seen this app before opening it here —"
echo "Gatekeeper caches a verdict per app, and this one has been run locally."
