#!/bin/bash
#
# Proves a built app actually runs: it carries the notices it owes, produces a
# snapshot quickly, hides the sensors cleanly when the private interfaces are
# refused, puts something in the menu bar, introduces itself to a Mac that has
# never run it, and exits when asked.
#
# Five of the seven are the ways this app has broken during development — a
# status item that never appeared, a sampler that never produced a reading,
# degradation that silently regressed, a quit that hung, and an install nobody
# could find. The other is the one that could not break loudly: a bundle
# without its NOTICE looks perfectly well from the outside.
#
# Every launch here runs against a throwaway `UserDefaults` domain
# (`CALIPER_DEFAULTS_SUITE`). Without one the checks below read whatever strip
# the person running them happens to have configured — and the first-run checks
# could not be written at all without walking over their settings.
#
# Usage: Scripts/smoke_test.sh [path/to/Caliper.app]

set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/lib.sh

APP=$(caliper_app_path "${1:-}")
BINARY="$APP/Contents/MacOS/Caliper"

# The checklist says "snapshot within 3 s". `--selftest` waits for the
# coordinator's *second* tick by design — the first only seeds the rate
# baselines — so two of those seconds are the measurement window itself, and
# the bar that means anything is two ticks plus launch.
MAX_SNAPSHOT_SECONDS=4

# One domain per launch, because a domain the app has been through is no longer
# a Mac that has never run it.
SUITE_SETTLED="caliper.smoketest.settled.$$"
SUITE_FRESH="caliper.smoketest.fresh.$$"
SUITE_UPGRADE="caliper.smoketest.upgrade.$$"

cleanup() {
    pkill -x Caliper 2>/dev/null || true
    for suite in "$SUITE_SETTLED" "$SUITE_FRESH" "$SUITE_UPGRADE"; do
        defaults delete "$suite" 2>/dev/null || true
        rm -f "$HOME/Library/Preferences/$suite.plist"
    done
}
trap cleanup EXIT

fail() {
    echo "FAIL: $1" >&2
    exit 1
}

# The strip the panel checks below tap by name: separate items, CPU and memory
# among them.
seed_settled() {
    defaults write "$SUITE_SETTLED" completedSetup -bool true
    defaults write "$SUITE_SETTLED" combinedMenuBarItem -bool false
    defaults write "$SUITE_SETTLED" menuBarLayout '{cpu = (enabled, graph, value); memory = (enabled, graph, value); network = (graph, value); disk = (graph, value); temperature = (enabled, graph, value);}'
    defaults write "$SUITE_SETTLED" menuBarOrder '(cpu, memory, network, disk, temperature)'
}

# Launches the app against one domain and waits for it to settle. Quits any
# instance first rather than killing it: a kill throws away the minute of
# history the recorder is holding.
launch_with() {
    caliper_stop "$BINARY" 2>/dev/null || true
    pkill -x Caliper 2>/dev/null || true
    sleep 1
    open --env "CALIPER_DEFAULTS_SUITE=$1" "$APP"
    sleep 4
}

[[ -x "$BINARY" ]] || fail "no executable at $BINARY"

# 1. The notice the bundled libraries' licences require is in the bundle. Its
#    absence is silent everywhere else: the settings sheet falls back to a
#    pointer rather than an empty pane, so a build that dropped the resource
#    looks fine and ships without what it owes.
[[ -f "$APP/Contents/Resources/NOTICE" ]] || fail "bundle carries no NOTICE"
echo "ok: third-party notice bundled"

# 2. A snapshot, quickly, with the metrics that matter in it.
START=$(date +%s)
SNAPSHOT=$("$BINARY" --selftest) || fail "--selftest exited non-zero"
ELAPSED=$(($(date +%s) - START))
((ELAPSED <= MAX_SNAPSHOT_SECONDS)) || fail "--selftest took ${ELAPSED}s"

for KEY in host cpu memory network; do
    # Top-level keys, not a substring match that a value could satisfy.
    echo "$SNAPSHOT" | plutil -extract "$KEY" json -o - -- - >/dev/null 2>&1 ||
        fail "snapshot has no $KEY"
done
echo "ok: snapshot in ${ELAPSED}s with cpu, memory and network"

# 3. Degradation: with the private sensor interfaces refused, the app must run
#    with the feature hidden rather than reporting zeros.
DEGRADED=$(CALIPER_DISABLE_SENSORS=1 "$BINARY" --selftest) || fail "degraded run exited non-zero"
if echo "$DEGRADED" | plutil -extract sensors json -o - -- - >/dev/null 2>&1; then
    fail "sensors present when disabled"
fi
echo "$DEGRADED" | plutil -extract cpu json -o - -- - >/dev/null 2>&1 ||
    fail "degraded run lost cpu"
echo "ok: sensors hidden cleanly when refused"

# 4. It launches and appears in the menu bar.
seed_settled
launch_with "$SUITE_SETTLED"

PID=$(caliper_pid "$BINARY")
[[ -n "$PID" ]] || fail "app is not running after launch"

# Menu bar *2*, not 1: menu bar 1 is the app's own menu across the top — Apple,
# Caliper, Edit, Window, four items whatever the strip is doing — and this check
# counted that one for as long as `MainMenu.install` has existed, which made it
# pass with an empty strip. Measured: 4 against the 3 status items, with the
# fixture's three modules in it.
#
# Counting needs Accessibility permission. Not having it is a limitation of the
# environment; having it and finding no strip is a failure, and the two must not
# collapse into the same answer — so permission is established against menu bar
# 1, which is there whatever happens, before menu bar 2 is asked about.
menu_bar_count() {
    osascript -e "tell application \"System Events\" to count of menu bar items of menu bar $1 of application process \"Caliper\"" 2>/dev/null
}
if menu_bar_count 1 >/dev/null; then
    ITEMS=$(menu_bar_count 2 || echo 0)
    # Three, because the fixture says three: a count nobody pinned would pass
    # with the strip half missing.
    ((ITEMS == 3)) || fail "expected 3 status items, counted ${ITEMS:-0}"
    echo "ok: $ITEMS status items"
else
    echo "warn: cannot count menu bar items — grant Accessibility permission to check this" >&2
fi

# 5. Opening a second panel must not take the app with it.
#
#    A popover is a window, and AppKit quits an app whose last window closes —
#    so opening panel two, which closes panel one, used to end the process with
#    no crash report to explain it. Scripted here because it is a two-click bug
#    that no unit test can reach.
KUROKO=$(caliper_kuroko)
# A kuroko that cannot run — an ended trial, a dead license — must read as
# absent, not as "the panel did not open": its tap exits nonzero before
# touching the app, and every failure after that would be the harness's own.
if [[ -n "$KUROKO" ]] && ! "$KUROKO" apps >/dev/null 2>&1; then
    KUROKO=""
fi
if [[ -n "$KUROKO" ]]; then
    "$KUROKO" tap com.olegklimakov.caliper --label "CPU" >/dev/null 2>&1 || true
    sleep 2
    [[ "$(caliper_window_count)" -gt 0 ]] || fail "first panel did not open"

    "$KUROKO" tap com.olegklimakov.caliper --label "Memory" >/dev/null 2>&1 || true
    sleep 2
    [[ -n "$(caliper_pid "$BINARY")" ]] || fail "app died when a second panel opened"
    [[ "$(caliper_window_count)" -gt 0 ]] || fail "second panel did not open"
    echo "ok: opened two panels in turn, app survived"

    # And the dashboard, which is only reachable from a panel.
    "$KUROKO" tap com.olegklimakov.caliper --label "History" >/dev/null 2>&1 || true
    sleep 3
    if "$KUROKO" inspect com.olegklimakov.caliper --window 2>/dev/null | grep -q "History unavailable"; then
        fail "dashboard cannot reach the history store"
    fi
    echo "ok: dashboard opened with history"
else
    # Saying so plainly, because a check that cannot open a panel proves
    # nothing about what happens when two of them are opened.
    echo "warn: Kuroko not found — the panel and dashboard checks verified nothing" >&2
fi

# 6. A Mac that has never run Caliper is told where it went.
#
#    The defect: `LSUIElement` plus no window at launch means a fresh install
#    draws a strip that a full menu bar may have no room for, and nothing else
#    at all. Counted through `CGWindowList` rather than Accessibility, so this
#    one check does not need a permission.
launch_with "$SUITE_FRESH"
[[ -n "$(caliper_pid "$BINARY")" ]] || fail "app is not running on a first launch"
[[ "$(caliper_window_count)" -gt 0 ]] || fail "first launch put up no window"
# The layout it seeds itself with, which is also what the flow opens on.
[[ "$(defaults read "$SUITE_FRESH" combinedMenuBarItem 2>/dev/null)" == "1" ]] ||
    fail "first launch did not seed the opening layout"
echo "ok: a first launch introduces itself"

#    And the other half of it: an update is not a first run. A domain carrying
#    a strip from an older version must launch into the menu bar and leave both
#    the strip and the screen alone.
defaults write "$SUITE_UPGRADE" menuBarLayout '{cpu = (enabled, icon, value);}'
launch_with "$SUITE_UPGRADE"
[[ -n "$(caliper_pid "$BINARY")" ]] || fail "app is not running after an upgrade launch"
[[ "$(caliper_window_count)" -eq 0 ]] || fail "an upgrade launch put up a window"
echo "ok: an upgrade launch says nothing"

# 7. It quits when asked.
caliper_stop "$BINARY"
sleep 2
[[ -z "$(caliper_pid "$BINARY")" ]] || fail "app still running after quit"
echo "ok: quit cleanly"

echo "PASS"
