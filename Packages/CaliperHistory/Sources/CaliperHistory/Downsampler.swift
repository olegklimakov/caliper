import Foundation
import GRDB

/// Rolls finer tiers up into coarser ones and deletes what has aged out.
///
/// Rollup is done in SQL rather than by reading rows into Swift: it is one
/// statement per tier whatever the volume, and with the sample counts stored
/// the aggregate of aggregates is exact — the extremes are the true extremes,
/// and the average is re-weighted rather than averaged again, which matters as
/// soon as two source buckets hold different numbers of readings.
public struct Downsampler: Sendable {
    private let store: HistoryStore

    public init(store: HistoryStore) {
        self.store = store
    }

    /// Rolls up complete buckets, then drops rows past each tier's retention.
    ///
    /// Every rollup happens before any delete. Interleaving them loses history:
    /// the ten-second rows older than a day would be deleted on the first pass
    /// of the loop, and the minute rows they should have become are only built
    /// on the second.
    ///
    /// `now` is a parameter so compaction can be tested without waiting a day
    /// for rows to age.
    ///
    /// `processRetention` is the user's choice for how long the process history
    /// lives; each tier caps it as `ProcessTier.retention(keeping:)` says.
    /// Off the caller's thread, like every other write in this package.
    ///
    /// It is the heaviest thing the app does to the store — three rollups, five
    /// deletes and an incremental vacuum — and it used to run synchronously on
    /// a cooperative thread while far cheaper reads were being careful to
    /// await.
    public func compact(
        now: Date = Date(),
        processRetention: TimeInterval = ProcessRetention.week.seconds
    ) async throws {
        try await store.databaseQueue.write { db in
            for tier in HistoryTier.allCases {
                if let source = tier.source {
                    try rollUp(from: source, into: tier, now: now, in: db)
                }
            }
            for tier in ProcessTier.allCases {
                if let source = tier.source {
                    try rollUpProcesses(from: source, into: tier, now: now, in: db)
                }
            }
            for tier in HistoryTier.allCases {
                try deleteExpired(tier, now: now, in: db)
            }
            for tier in ProcessTier.allCases {
                try deleteExpiredProcesses(tier, retention: processRetention, now: now, in: db)
            }
            try collectProcessNames(in: db)
            // Hand back a bounded number of the pages those deletes freed.
            // Incremental rather than a full `VACUUM`, which would rewrite the
            // whole file under a long lock to reclaim what a day of retention
            // released.
            try db.execute(sql: "PRAGMA incremental_vacuum(256)")
        }
    }

    /// How far back a rolled-up bucket is still rebuilt from its sources.
    ///
    /// Nothing ever writes fine rows for a span older than the one being
    /// recorded, so an hour is far more slack than a flush interval or a
    /// relaunch needs, and it keeps the rewrite to a few hundred rows a pass
    /// rather than the ten thousand a full-retention rebuild would touch.
    ///
    /// Two things about this number are load-bearing. It must stay **shorter
    /// than the shortest source retention** — a day, for the ten-second tier —
    /// or a bucket could be rebuilt from sources that have partly aged out, and
    /// a good row would be replaced by a thin one. And it must be a **whole
    /// number of every tier's buckets**, which an hour is for all four widths,
    /// so that the boundary between "settled" and "still rebuilt" always falls
    /// on a bucket edge rather than through the middle of one.
    static let rebuildWindow: TimeInterval = 3600

    private func rollUp(
        from source: HistoryTier,
        into target: HistoryTier,
        now: Date,
        in db: Database
    ) throws {
        // Only buckets that have finished: rolling up the one still filling
        // would write a target row that later readings would have changed.
        let cutoff = Int(now.timeIntervalSince1970) / target.seconds * target.seconds
        let settled = cutoff - Int(Self.rebuildWindow)

        // Two passes over disjoint ranges.
        //
        // Older than the window a bucket is built once and never touched again,
        // which is all this used to do — a target bucket was said to be built
        // from a source complete by construction. Six days of real recording
        // say otherwise: 32 of 722 ten-minute buckets disagreed with the minute
        // rows under them, by up to seven points of CPU, and every one was a
        // span where recording had stopped and started. Fine rows landing after
        // the bucket was built were locked out of it for the life of the file.
        //
        // So the recent end is rebuilt from its sources on every pass. A
        // rolled-up value is a pure function of those rows, which makes
        // recomputing it idempotent by construction; refusing to recompute was
        // the fragile half.
        try rollUp(from: source, into: target, buckets: Int.min..<settled, rebuild: false, in: db)
        try rollUp(from: source, into: target, buckets: settled..<cutoff, rebuild: true, in: db)
    }

    /// One range of target buckets, built from the rows under them.
    ///
    /// `rebuild` says what to do about a bucket that is already there:
    /// overwrite it with the recomputed aggregate, or leave it alone. Never a
    /// merge — merging would re-add the same source rows to the count on every
    /// pass.
    private func rollUp(
        from source: HistoryTier,
        into target: HistoryTier,
        buckets: Range<Int>,
        rebuild: Bool,
        in db: Database
    ) throws {
        let onConflict =
            rebuild
            ? """
            DO UPDATE SET
                minimum = excluded.minimum,
                average = excluded.average,
                maximum = excluded.maximum,
                count = excluded.count
            """
            : "DO NOTHING"

        try db.execute(
            sql: """
                INSERT INTO \(target.tableName)
                    (series, timestamp, minimum, average, maximum, count)
                SELECT
                    series,
                    timestamp / :width * :width AS bucket,
                    min(minimum),
                    sum(average * count) / sum(count),
                    max(maximum),
                    sum(count)
                FROM \(source.tableName)
                WHERE timestamp >= :from AND timestamp < :until
                GROUP BY series, bucket
                ON CONFLICT (series, timestamp) \(onConflict)
                """,
            arguments: ["width": target.seconds, "from": buckets.lowerBound, "until": buckets.upperBound]
        )
    }

    /// Rolls thirty-second process buckets into minutes, re-ranking as it goes.
    ///
    /// This cannot be `rollUp`'s plain `GROUP BY`. A metric series is in every
    /// source bucket, so merging is arithmetic; the *set of processes* differs
    /// between two source buckets, so their union is longer than either and has
    /// to be cut back to a top ten afterwards. `ROW_NUMBER()` does that in the
    /// same statement, which SQLite has had since 3.25.
    ///
    /// A process present in only one of the two source buckets is averaged over
    /// the buckets it appeared in, not over both: absence means "not in the top
    /// ten", not "idle", and dividing by a bucket it was never ranked in would
    /// halve a number that was never halved in reality.
    private func rollUpProcesses(
        from source: ProcessTier,
        into target: ProcessTier,
        now: Date,
        in db: Database
    ) throws {
        let cutoff = Int(now.timeIntervalSince1970) / target.seconds * target.seconds
        let settled = cutoff - Int(Self.rebuildWindow)

        // The recent end is thrown away and built again, for the reason the
        // metric rollup rebuilds it: a bucket built while recording was paused
        // inside its span is missing the rows that arrived afterwards, and
        // `DO NOTHING` would keep it that way for good.
        //
        // A delete rather than the metric tier's `DO UPDATE`, because this
        // rollup re-ranks: a process that falls out of the top ten on the
        // rebuild has to leave the bucket, and an update can only overwrite
        // rows, never remove one. The whole compaction is one transaction, so
        // the window is never observed empty.
        try db.execute(
            sql: "DELETE FROM \(target.tableName) WHERE timestamp >= ? AND timestamp < ?",
            arguments: [settled, cutoff]
        )

        try db.execute(
            sql: """
                INSERT INTO \(target.tableName)
                    (timestamp, name_id, cpu_permille, footprint_mb, disk_kbps, count)
                SELECT timestamp, name_id, cpu_permille, footprint_mb, disk_kbps, count
                FROM (
                    SELECT
                        timestamp / :width * :width AS timestamp,
                        name_id,
                        sum(cpu_permille * count) / sum(count) AS cpu_permille,
                        max(footprint_mb) AS footprint_mb,
                        sum(disk_kbps * count) / sum(count) AS disk_kbps,
                        sum(count) AS count,
                        row_number() OVER (
                            PARTITION BY timestamp / :width * :width
                            ORDER BY sum(cpu_permille * count) / sum(count) DESC
                        ) AS cpu_rank,
                        row_number() OVER (
                            PARTITION BY timestamp / :width * :width
                            ORDER BY max(footprint_mb) DESC
                        ) AS memory_rank
                    FROM \(source.tableName)
                    WHERE timestamp < :cutoff
                    GROUP BY timestamp / :width * :width, name_id
                )
                WHERE cpu_rank <= :limit OR memory_rank <= :limit
                ON CONFLICT (timestamp, name_id) DO NOTHING
                """,
            arguments: ["width": target.seconds, "cutoff": cutoff, "limit": ProcessTier.topCount]
        )
    }

    private func deleteExpiredProcesses(
        _ tier: ProcessTier,
        retention: TimeInterval,
        now: Date,
        in db: Database
    ) throws {
        let horizon = Int(
            now.addingTimeInterval(-tier.retention(keeping: retention)).timeIntervalSince1970
        )
        try db.execute(
            sql: "DELETE FROM \(tier.tableName) WHERE timestamp < ?",
            arguments: [horizon]
        )
    }

    /// Drops interned names no tier refers to any more.
    ///
    /// Without this the name table grows forever with every short-lived build
    /// script the machine ever ran — the rows it names are deleted by
    /// retention, but the name outlives them.
    private func collectProcessNames(in db: Database) throws {
        let referenced = ProcessTier.allCases
            .map { "SELECT name_id FROM \($0.tableName)" }
            .joined(separator: " UNION ")
        try db.execute(sql: "DELETE FROM process_names WHERE id NOT IN (\(referenced))")
    }

    private func deleteExpired(_ tier: HistoryTier, now: Date, in db: Database) throws {
        let horizon = Int(now.addingTimeInterval(-tier.retention).timeIntervalSince1970)
        try db.execute(
            sql: "DELETE FROM \(tier.tableName) WHERE timestamp < ?",
            arguments: [horizon]
        )
    }
}
