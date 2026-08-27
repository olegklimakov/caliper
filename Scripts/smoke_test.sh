#!/bin/bash
#
# Proves a built app actually runs: it carries the notices it owes, produces a
# snapshot quickly, hides the sensors cleanly when the private interfaces are
# refused, puts something in the menu bar, and exits when asked.
#
# Four of the five are the ways this app has broken during development — a
# status item that never appeared, a sampler that never produced a reading,
# degradation that silently regressed, and a quit that hung. The fifth is the
# one that could not break loudly: a bundle without its NOTICE looks perfectly
# well from the outside.
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

fail() {
    echo "FAIL: $1" >&2
    pkill -x Caliper 2>/dev/null || true
    exit 1
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
pkill -x Caliper 2>/dev/null || true
open "$APP"
sleep 4

PID=$(caliper_pid "$BINARY")
[[ -n "$PID" ]] || fail "app is not running after launch"

# Counting menu bar items needs Accessibility permission. Not having it is a
# limitation of the environment; having it and counting zero is a failure, and
# the two must not collapse into the same answer.
if ITEMS=$(osascript -e 'tell application "System Events" to count of menu bar items of menu bar 1 of application process "Caliper"' 2>/dev/null); then
    ((ITEMS > 0)) || fail "no menu bar items"
    echo "ok: $ITEMS menu bar items"
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

# 6. It quits when asked.
caliper_stop "$BINARY"
sleep 2
[[ -z "$(caliper_pid "$BINARY")" ]] || fail "app still running after quit"
echo "ok: quit cleanly"

echo "PASS"
