#!/bin/bash
#
# Shared by the harnesses. Locating the app, starting and stopping it and
# reading its footprint are the same job in both, and two copies of a
# measurement are two chances to measure it differently.

# Path to the release app, unless one was given.
caliper_app_path() {
    local given="${1:-}"
    if [[ -n "$given" ]]; then
        echo "$given"
        return
    fi
    local products
    products=$(xcodebuild -project Caliper.xcodeproj -scheme Caliper -configuration Release \
        -showBuildSettings 2>/dev/null | awk -F' = ' '/ BUILT_PRODUCTS_DIR/{print $2}')
    echo "$products/Caliper.app"
}

# The running pid, or empty.
#
# Matched on the executable name, never with `pgrep -f`: the full command line
# of this very script contains the path to the binary, so a pattern match finds
# the harness itself and reports the app as running — or, once the wrapper
# exits, as having died. Deliberately tolerant of "not running": under `set -e`
# a bare `pgrep` that finds nothing takes the script down before it can report
# anything useful.
caliper_pid() {
    local binary="${1:-}"
    local pid
    for pid in $(pgrep -x Caliper 2>/dev/null || true); do
        # Only the build under test. `pgrep -x` matches by name, so an installed
        # copy in /Applications answers to it too, and killing the user's own
        # running app to measure a build is not a trade any harness gets to
        # make. `ps -o comm=` gives the executable's full path, so the caller
        # passes the same.
        if [[ -z "$binary" || "$(ps -p "$pid" -o comm= 2>/dev/null)" == "$binary" ]]; then
            echo "$pid"
            return
        fi
    done
}

caliper_stop() {
    local binary="${1:-}"
    osascript -e 'tell application "Caliper" to quit' >/dev/null 2>&1 || true
    sleep 2
    local pid
    pid=$(caliper_pid "$binary")
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
}

# Physical footprint in megabytes, as `vmmap` reports it.
#
# The units vary with size — vmmap writes K, M or G — and an unrecognised one
# must be an error rather than a zero: a harness that reads "1.2G" as nothing
# passes hardest exactly when the app is worst.
caliper_footprint_mb() {
    local pid="$1" raw
    raw=$(vmmap --summary "$pid" 2>/dev/null | awk '/Physical footprint:/ {print $3}' | head -1)

    if [[ -z "$raw" ]]; then
        echo "could not read footprint of pid $pid" >&2
        return 1
    fi

    local number="${raw%[KMG]}"
    case "$raw" in
    *K) echo "scale=1; $number / 1024" | bc ;;
    *M) echo "scale=1; $number / 1" | bc ;;
    *G) echo "scale=1; $number * 1024" | bc ;;
    *)
        echo "unrecognised footprint unit in '$raw'" >&2
        return 1
        ;;
    esac
}

# Mean CPU as a share of one core over the process's life so far.
#
# Not `ps %cpu`: that is a decaying average over roughly the last minute, so a
# half-hour run would be judged on its final sixty seconds. Total CPU time
# divided by elapsed time is the mean the budget is actually written against.
caliper_mean_cpu_percent() {
    local pid="$1"
    local cpu_time elapsed
    cpu_time=$(ps -o time= -p "$pid" | tr -d ' ')
    elapsed=$(ps -o etime= -p "$pid" | tr -d ' ')

    local cpu_seconds elapsed_seconds
    cpu_seconds=$(caliper_duration_seconds "$cpu_time")
    elapsed_seconds=$(caliper_duration_seconds "$elapsed")

    if [[ -z "$elapsed_seconds" || "$elapsed_seconds" == "0" ]]; then
        echo "could not read process times" >&2
        return 1
    fi
    echo "scale=2; $cpu_seconds * 100 / $elapsed_seconds" | bc
}

# `ps` writes durations as [[dd-]hh:]mm:ss.
caliper_duration_seconds() {
    echo "$1" | awk -F'[-:]' '{
        if (NF == 4)      { print ($1 * 86400) + ($2 * 3600) + ($3 * 60) + $4 }
        else if (NF == 3) { print ($1 * 3600) + ($2 * 60) + $3 }
        else if (NF == 2) { print ($1 * 60) + $2 }
        else              { print $1 }
    }'
}

# Number of on-screen windows the app owns.
#
# A popover is a window, so this is how the harness can tell a panel actually
# opened rather than assuming a click did something. Needs no permission —
# unlike driving the menu bar through System Events.
caliper_window_count() {
    /usr/bin/swift -e '
import CoreGraphics
import Foundation
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
print(windows.filter { ($0[kCGWindowOwnerName as String] as? String) == "Caliper" }.count)
' 2>/dev/null || echo 0
}

# Path to Kuroko, the tool that can actually drive this app.
#
# System Events cannot open the panels — a scripted click on a status item does
# nothing — so any check that claims to open one needs Kuroko's AX driver.
# Absent, the caller should say it verified nothing rather than pass.
caliper_kuroko() {
    if command -v kuroko >/dev/null 2>&1; then
        command -v kuroko
        return
    fi
    local built="$HOME/Projects/Kuroko/.build/debug/kuroko"
    [[ -x "$built" ]] && echo "$built"
}

# Where the recorded history lives.
#
# The app writes to the app group container when its build is signed for it and
# to Application Support otherwise, and a machine that has run both has both.
# The most recently written one is the one being recorded into — preferring the
# container by name reconciles whichever file a signed build touched once,
# months ago, and reports PASS over fourteen rows. An explicit path always wins.
caliper_store_path() {
    if [[ -n "${1:-}" ]]; then
        echo "$1"
        return
    fi
    local candidates=(
        "$HOME/Library/Group Containers/GCCNH99PN6.caliper/history.sqlite"
        "$HOME/Library/Application Support/Caliper/history.sqlite"
    )
    # Judged by the write-ahead log, not the database file: under WAL the main
    # file's timestamp only moves at a checkpoint, so a store being written to
    # right now can look older than one nothing has touched for a week.
    local newest="" newest_mark="" path mark
    for path in "${candidates[@]}"; do
        [[ -f "$path" ]] || continue
        mark="$path"
        [[ -f "$path-wal" ]] && mark="$path-wal"
        if [[ -z "$newest" || "$mark" -nt "$newest_mark" ]]; then
            newest="$path"
            newest_mark="$mark"
        fi
    done
    echo "$newest"
}
