#!/bin/bash
#
# Measures what Caliper costs the machine it is measuring.
#
# PRD §6: menu-bar-only steady state must stay under 1 % mean CPU and 50 MB.
# The memory figure is *physical footprint*, not RSS: RSS counts shared AppKit
# and SwiftUI pages — about 70 MB of framework text on this app — that would be
# resident whether Caliper ran or not. Physical footprint is what Activity
# Monitor calls "Memory" and what the app actually costs.
#
# With --card, it measures a second phase with a process card open and prints
# the delta. That state is deliberately more expensive — a rusage pass and a
# GPU sweep a second for one family, plus the window they are drawn in — and
# has no budget of its own: what Phase 7 promises is that it is *bounded by
# being on screen*, which only a number beside the idle one can show.
#
# Usage: Scripts/footprint_check.sh [minutes] [path/to/Caliper.app] [--card NAME]

set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/lib.sh

MINUTES=""
APP_ARGUMENT=""
CARD=""
while (($# > 0)); do
    case "$1" in
    --card)
        CARD="${2:-}"
        if [[ -z "$CARD" ]]; then
            echo "--card needs a process name" >&2
            exit 1
        fi
        shift 2
        ;;
    -*)
        echo "unknown option: $1" >&2
        echo "usage: Scripts/footprint_check.sh [minutes] [path/to/Caliper.app] [--card NAME]" >&2
        exit 1
        ;;
    *)
        if [[ -z "$MINUTES" ]]; then
            MINUTES="$1"
        elif [[ -z "$APP_ARGUMENT" ]]; then
            APP_ARGUMENT="$1"
        else
            echo "unexpected argument: $1" >&2
            exit 1
        fi
        shift
        ;;
    esac
done

MINUTES="${MINUTES:-30}"
# Checked before it reaches arithmetic: a mistyped option taken as the minutes
# fails inside `$((...))` half the script away from the mistake, and this is a
# command someone comes back to an hour later.
if ! [[ "$MINUTES" =~ ^[1-9][0-9]*$ ]]; then
    echo "minutes must be a positive whole number, got: $MINUTES" >&2
    exit 1
fi
APP=$(caliper_app_path "$APP_ARGUMENT")
BINARY="$APP/Contents/MacOS/Caliper"
MAX_CPU_PERCENT="1.0"
MAX_FOOTPRINT_MB="50"
SAMPLE_INTERVAL=10

if [[ ! -x "$BINARY" ]]; then
    echo "no release build at $APP — run xcodebuild -configuration Release first" >&2
    exit 1
fi

# Set by `measure`, which cannot return two numbers.
MEAN_CPU=0
PEAK_FOOTPRINT=0

# One phase: launch with the given arguments, watch it for MINUTES, and leave
# the mean CPU and peak footprint behind.
#
# `windows` is what the phase is *about*, and it is asserted rather than
# assumed. `open` hands `--args` only to a new instance, an older bundle would
# not know the flag at all, and a phase that quietly measured the idle state
# under the heading "card open" would report a delta of nothing and read as
# good news. Measured on this machine: menu-bar-only owns no on-screen window,
# a card open owns one.
measure() {
    local label="$1" windows="$2"
    shift 2

    echo "measuring $MINUTES min: $label"
    pkill -x Caliper 2>/dev/null || true
    # `-a` with `--args`, and only after the pkill: `open` hands arguments to a
    # *new* instance and silently just fronts an existing one.
    open -a "$APP" --args "$@"
    sleep 5

    local pid
    pid=$(caliper_pid "$BINARY")
    if [[ -z "$pid" ]]; then
        echo "FAIL: app did not start" >&2
        exit 1
    fi
    echo "pid: $pid"
    assert_windows "$windows" "at launch"

    local samples=$((MINUTES * 60 / SAMPLE_INTERVAL))
    PEAK_FOOTPRINT=0

    local i current footprint
    for ((i = 1; i <= samples; i++)); do
        sleep "$SAMPLE_INTERVAL"

        # The *same* process must still be there. Merely finding some Caliper
        # process would let a crash and relaunch pass as a clean half hour, and
        # the mean CPU at the end would then describe only the survivor.
        current=$(caliper_pid "$BINARY")
        if [[ -z "$current" ]]; then
            echo "FAIL: app exited after $((i * SAMPLE_INTERVAL / 60)) min" >&2
            exit 1
        fi
        if [[ "$current" != "$pid" ]]; then
            echo "FAIL: app restarted after $((i * SAMPLE_INTERVAL / 60)) min" >&2
            exit 1
        fi

        footprint=$(caliper_footprint_mb "$pid")
        if (($(echo "$footprint > $PEAK_FOOTPRINT" | bc -l))); then
            PEAK_FOOTPRINT=$footprint
        fi

        if ((i % 6 == 0)); then
            printf "  %3d min: footprint %s MB\n" "$((i * SAMPLE_INTERVAL / 60))" "$footprint"
        fi
    done

    # Again at the end rather than on every sample: each check compiles a Swift
    # snippet, and two that bracket the phase catch both a card that never
    # opened and a window closed halfway.
    assert_windows "$windows" "after $MINUTES min"

    MEAN_CPU=$(caliper_mean_cpu_percent "$pid")
    caliper_stop "$BINARY"
}

assert_windows() {
    local wanted="$1" when="$2" found
    found=$(caliper_window_count)
    if [[ "$found" != "$wanted" ]]; then
        echo "FAIL: expected $wanted on-screen window(s) $when, found $found" >&2
        exit 1
    fi
}

echo "app: $APP"
measure "menu bar only" 0
IDLE_CPU=$MEAN_CPU
IDLE_FOOTPRINT=$PEAK_FOOTPRINT

echo
echo "menu bar only"
# `bc` writes a bare ".60" for six tenths, which reads as a missing digit in a
# report that is mostly about the digit before the point.
printf "  mean CPU:        %.2f%%  (budget %s%%)\n" "$IDLE_CPU" "$MAX_CPU_PERCENT"
echo "  peak footprint:  ${IDLE_FOOTPRINT} MB  (budget ${MAX_FOOTPRINT_MB} MB)"

FAILED=0
if (($(echo "$IDLE_CPU > $MAX_CPU_PERCENT" | bc -l))); then
    echo "FAIL: mean CPU over budget" >&2
    FAILED=1
fi
if (($(echo "$IDLE_FOOTPRINT > $MAX_FOOTPRINT_MB" | bc -l))); then
    echo "FAIL: footprint over budget" >&2
    FAILED=1
fi

if [[ -n "$CARD" ]]; then
    echo
    measure "a card open on \"$CARD\"" 1 --open-card "$CARD"
    echo
    echo "card open"
    printf "  mean CPU:        %.2f%%\n" "$MEAN_CPU"
    echo "  peak footprint:  ${PEAK_FOOTPRINT} MB"
    echo
    # The window the card is drawn in is part of this: it charts five metrics
    # of its own and puts the samplers on their visible cadence. There is no
    # flag that opens the dashboard without a card, so the delta is "the card
    # and the room it lives in" and must be read as that.
    echo "delta, card and its window against idle"
    printf "  mean CPU:        %+.2f pp\n" "$(echo "$MEAN_CPU - $IDLE_CPU" | bc -l)"
    printf "  peak footprint:  %+.1f MB\n" "$(echo "$PEAK_FOOTPRINT - $IDLE_FOOTPRINT" | bc -l)"
fi

echo
((FAILED == 0)) && echo "PASS"
exit "$FAILED"
