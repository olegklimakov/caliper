#!/bin/bash
#
# Reconciles the tiered store against itself, on a machine that has really been
# recording.
#
# The unit tests write a day of samples in one go and prove the arithmetic. What
# they cannot show is what a week of *interrupted* recording does to it: the app
# is quit, the Mac sleeps, a second instance runs during a footprint check, and
# fine rows keep arriving for a span whose coarse bucket has already been built.
# A rolled-up value is a pure function of the rows under it, so every bucket can
# be rebuilt from its source and compared with what is stored. Anything that
# disagrees was built from rows that are no longer all it should have had.
#
# This is what found the bug it now guards: 32 of 722 ten-minute buckets
# disagreed with their own minute rows, by up to seven points of CPU, because
# `ON CONFLICT DO NOTHING` locked out anything that arrived late. Buckets from
# before that fix cannot be repaired — their sources may have aged out — so they
# are reported and not failed. Inside the window the rollup still rebuilds, and
# a mismatch there is a live bug.
#
# Usage: Scripts/soak_check.sh [path/to/history.sqlite]

set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/lib.sh

DB=$(caliper_store_path "${1:-}")
# Must match `Downsampler.rebuildWindow`.
REBUILD_WINDOW_SECONDS=3600

if [[ -z "$DB" || ! -f "$DB" ]]; then
    echo "no history store found — run the app for a while first" >&2
    exit 1
fi

echo "reconciling $DB"
echo

# Read-only, and over a copy of nothing: the app may be running and writing.
# WAL means a reader never blocks it and never sees a partial transaction.
query() { sqlite3 "file:$DB?mode=ro" "$@"; }

printf '%-12s %10s  %-19s  %-19s\n' tier rows from to
query <<'SQL' | while IFS='|' read -r tier rows first last; do
SELECT 'samples_10s', count(*), coalesce(datetime(min(timestamp),'unixepoch'),'—'),
       coalesce(datetime(max(timestamp),'unixepoch'),'—') FROM samples_10s
UNION ALL SELECT 'samples_1m', count(*), coalesce(datetime(min(timestamp),'unixepoch'),'—'),
       coalesce(datetime(max(timestamp),'unixepoch'),'—') FROM samples_1m
UNION ALL SELECT 'samples_10m', count(*), coalesce(datetime(min(timestamp),'unixepoch'),'—'),
       coalesce(datetime(max(timestamp),'unixepoch'),'—') FROM samples_10m
UNION ALL SELECT 'samples_1h', count(*), coalesce(datetime(min(timestamp),'unixepoch'),'—'),
       coalesce(datetime(max(timestamp),'unixepoch'),'—') FROM samples_1h
SQL
    printf '%-12s %10s  %-19s  %-19s\n' "$tier" "$rows" "$first" "$last"
done
echo

FAILED=0

# Every coarse bucket, rebuilt from the rows under it. `count` is the sharper
# test of the two — an average can coincide, a reading count cannot — but both
# are checked, because a rebuilt average that differs while the count matches
# would mean the arithmetic itself had drifted.
reconcile() {
    local target="$1" source="$2" width="$3"
    # The same boundary the rollup uses: buckets at or after `cutoff - window`,
    # where the cutoff is now aligned down to this tier's width. Comparing a
    # bucket's timestamp against `now - window` instead misses the last bucket
    # of every tier — and for the hour tier, whose only in-window bucket always
    # starts more than an hour ago, it misses all of them and the check is dead.
    local horizon
    horizon=$(( $(date +%s) / width * width - REBUILD_WINDOW_SECONDS ))

    local result
    result=$(query <<SQL
WITH rebuilt AS (
    SELECT series, timestamp / $width * $width AS bucket,
           sum(average * count) / sum(count) AS average,
           sum(count) AS n
    FROM $source GROUP BY series, bucket
),
-- The oldest bucket the source can still answer for in full. Retention deletes
-- fine rows by age, not by bucket, so the oldest surviving coarse span is half
-- gone and would disagree for a reason that is not a bug.
covered AS (
    SELECT (min(timestamp) + $width - 1) / $width * $width AS first FROM $source
),
compared AS (
    SELECT t.timestamp, t.series,
           -- Relative, not absolute: these series are bytes per second as well
           -- as fractions, and an epsilon that suits 0.34 calls every download
           -- a mismatch.
           t.count <> r.n
           OR abs(t.average - r.average) > 1e-6 * max(abs(r.average), 1) AS wrong,
           abs(t.average - r.average) / max(abs(r.average), 1) AS drift
    FROM $target t
    JOIN rebuilt r ON r.series = t.series AND r.bucket = t.timestamp
    WHERE t.timestamp >= (SELECT first FROM covered)
)
SELECT (SELECT count(*) FROM $target WHERE timestamp >= (SELECT first FROM covered)),
       count(*),
       coalesce(sum(wrong), 0),
       coalesce(sum(wrong AND timestamp >= $horizon), 0),
       coalesce((SELECT series FROM compared ORDER BY drift DESC LIMIT 1), '—'),
       coalesce(round(max(drift), 9), 0)
FROM compared;
SQL
    )
    local inrange compared stale recent series worst
    IFS='|' read -r inrange compared stale recent series worst <<<"$result"

    # `compared` against `inrange` is the check on the check: an inner join
    # silently drops every bucket whose sources are gone, and a source table
    # that is empty altogether would otherwise compare nothing and report PASS.
    printf '%-12s %6s of %6s rebuilt  disagreeing %4s (%s inside the window)  worst drift %s on %s\n' \
        "$target" "$compared" "$inrange" "$stale" "$recent" "$worst" "$series"

    if ((recent > 0)); then
        echo "FAIL: $recent $target buckets inside the rebuild window disagree with $source" >&2
        FAILED=1
    fi
}

# Only pairs where the source is still retained: the finest tier is kept a day,
# so ten-minute buckets older than that have nothing left to be checked against
# and are simply absent from the join.
reconcile samples_1m samples_10s 60
reconcile samples_10m samples_1m 600
reconcile samples_1h samples_10m 3600

echo
((FAILED == 0)) && echo "PASS"
exit "$FAILED"
