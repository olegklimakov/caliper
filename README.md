# Caliper

A native macOS menu bar system monitor: live CPU, memory, disk, network and
temperature readings in the menu bar, a detail panel behind each one, and a
dashboard with long-term history.

Requires macOS 15 or later, Apple Silicon.

## Downloads

Releases are published here as notarized disk images. Nothing is out yet — the
first build lands when the MVP is finished.

## Updates

The app updates itself through [Sparkle](https://sparkle-project.org). This
repository is the update channel: each release attaches its DMG here, and
`appcast.xml` at the root of the published site is the feed the app reads. The
signing key's public half ships inside the app, so a build only installs an
update this repository actually signed.

## Source

The source lives in a separate private repository. This one exists so the
update feed stays public and stable no matter what happens to the source: an
installed copy keeps updating even if the code never opens.
