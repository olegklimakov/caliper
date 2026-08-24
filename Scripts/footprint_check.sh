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
# Usage: Scripts/footprint_check.sh [minutes] [path/to/Caliper.app]

set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/lib.sh

MINUTES="${1:-30}"
APP=$(caliper_app_path "${2:-}")
BINARY="$APP/Contents/MacOS/Caliper"
MAX_CPU_PERCENT="1.0"
MAX_FOOTPRINT_MB="50"
SAMPLE_INTERVAL=10

if [[ ! -x "$BINARY" ]]; then
    echo "no release build at $APP — run xcodebuild -configuration Release first" >&2
    exit 1
fi

echo "measuring $MINUTES min of menu-bar-only steady state"
echo "app: $APP"

pkill -x Caliper 2>/dev/null || true
open "$APP"
sleep 5

PID=$(caliper_pid "$BINARY")
if [[ -z "$PID" ]]; then
    echo "FAIL: app did not start" >&2
    exit 1
fi
echo "pid: $PID"

SAMPLES=$((MINUTES * 60 / SAMPLE_INTERVAL))
PEAK_FOOTPRINT=0

for ((i = 1; i <= SAMPLES; i++)); do
    sleep "$SAMPLE_INTERVAL"

    # The *same* process must still be there. Merely finding some Caliper
    # process would let a crash and relaunch pass as a clean half hour, and
    # the mean CPU at the end would then describe only the survivor.
    CURRENT=$(caliper_pid "$BINARY")
    if [[ -z "$CURRENT" ]]; then
        echo "FAIL: app exited after $((i * SAMPLE_INTERVAL / 60)) min" >&2
        exit 1
    fi
    if [[ "$CURRENT" != "$PID" ]]; then
        echo "FAIL: app restarted after $((i * SAMPLE_INTERVAL / 60)) min" >&2
        exit 1
    fi

    FOOTPRINT_MB=$(caliper_footprint_mb "$PID")
    if (($(echo "$FOOTPRINT_MB > $PEAK_FOOTPRINT" | bc -l))); then
        PEAK_FOOTPRINT=$FOOTPRINT_MB
    fi

    if ((i % 6 == 0)); then
        printf "  %3d min: footprint %s MB\n" "$((i * SAMPLE_INTERVAL / 60))" "$FOOTPRINT_MB"
    fi
done

MEAN_CPU=$(caliper_mean_cpu_percent "$PID")
caliper_stop "$BINARY"

echo
echo "mean CPU:          ${MEAN_CPU}%  (budget ${MAX_CPU_PERCENT}%)"
echo "peak footprint:    ${PEAK_FOOTPRINT} MB  (budget ${MAX_FOOTPRINT_MB} MB)"

FAILED=0
if (($(echo "$MEAN_CPU > $MAX_CPU_PERCENT" | bc -l))); then
    echo "FAIL: mean CPU over budget" >&2
    FAILED=1
fi
if (($(echo "$PEAK_FOOTPRINT > $MAX_FOOTPRINT_MB" | bc -l))); then
    echo "FAIL: footprint over budget" >&2
    FAILED=1
fi

((FAILED == 0)) && echo "PASS"
exit "$FAILED"
