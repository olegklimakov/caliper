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
    /// for rows to age. `processRetention` is the user's choice, capped per tier
    /// by `ProcessTier.retention(keeping:)`.
    ///
    /// The heaviest thing the app does to the store — three rollups, five
    /// deletes and an incremental vacuum — so it stays off the caller's thread.
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
            try deleteExpiredRegistry(retention: processRetention, now: now, in: db)
            try collectProcessNames(in: db)
            // Hand back a bounded number of the pages those deletes freed.
            // Incremental rather than a full `VACUUM`, which would rewrite the
            // whole file under a long lock to reclaim what a day of retention
            // released.
            try db.execute(sql: "PRAGMA incremental_vacuum(256)")
        }
    }

    /// How far back a rolled-up bucket is still rebuilt from its sources. An
    /// hour keeps the rewrite to a few hundred rows a pass.
    ///
    /// Two constraints are load-bearing. It must stay **shorter than the
    /// shortest source retention** — a day, for the ten-second tier — or a
    /// bucket gets rebuilt from sources that have partly aged out, replacing a
    /// good row with a thin one. And it must be a **whole number of every
    /// tier's buckets**, so the settled boundary falls on a bucket edge.
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

        // Two passes over disjoint ranges: settled buckets are built once, the
        // recent end is rebuilt from its sources every pass.
        //
        // Build-once alone is not enough. Over six days of real recording, 32
        // of 722 ten-minute buckets disagreed with the minute rows under them
        // by up to seven points of CPU — every one a span where recording had
        // stopped and started, with the late-arriving fine rows locked out for
        // the life of the file. A rolled-up value is a pure function of its
        // sources, so recomputing is idempotent.
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

        // Thrown away and rebuilt, for the reason the metric rollup rebuilds.
        // A delete rather than `DO UPDATE` because this rollup re-ranks: a
        // process that falls out of the top ten has to leave the bucket, and an
        // update can overwrite rows but never remove one. One transaction, so
        // the window is never observed empty. Re-ranking is also why `keep`
        // exists — a pinned row ranks nowhere and would be re-evicted here.
        try db.execute(
            sql: "DELETE FROM \(target.tableName) WHERE timestamp >= ? AND timestamp < ?",
            arguments: [settled, cutoff]
        )

        try db.execute(
            sql: """
                INSERT INTO \(target.tableName)
                    (timestamp, name_id, cpu_permille, footprint_mb, disk_kbps,
                     energy_mj, keep, count)
                SELECT timestamp, name_id, cpu_permille, footprint_mb, disk_kbps,
                       energy_mj, keep, count
                FROM (
                    SELECT
                        timestamp / :width * :width AS timestamp,
                        name_id,
                        sum(cpu_permille * count) / sum(count) AS cpu_permille,
                        max(footprint_mb) AS footprint_mb,
                        sum(disk_kbps * count) / sum(count) AS disk_kbps,
                        sum(energy_mj) AS energy_mj,
                        max(keep) AS keep,
                        sum(count) AS count,
                        row_number() OVER (
                            PARTITION BY timestamp / :width * :width
                            ORDER BY sum(cpu_permille * count) / sum(count) DESC
                        ) AS cpu_rank,
                        row_number() OVER (
                            PARTITION BY timestamp / :width * :width
                            ORDER BY max(footprint_mb) DESC
                        ) AS memory_rank,
                        -- Ranked among the rows that drew any: most of the
                        -- machine draws none, and a rank over a tie of zeroes
                        -- keeps ten arbitrary rows. The same rule the recorder
                        -- applies when it closes a bucket.
                        row_number() OVER (
                            PARTITION BY timestamp / :width * :width
                            ORDER BY sum(energy_mj) DESC
                        ) AS energy_rank
                    FROM \(source.tableName)
                    WHERE timestamp < :cutoff
                    GROUP BY timestamp / :width * :width, name_id
                )
                WHERE cpu_rank <= :limit OR memory_rank <= :limit
                    OR (energy_rank <= :limit AND energy_mj > 0) OR keep > 0
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

    /// The registry ages out on the user's whole choice rather than per tier:
    /// it has no tiers, and "first seen" is a claim about the window that is
    /// kept, not about the machine's whole life.
    private func deleteExpiredRegistry(
        retention: TimeInterval,
        now: Date,
        in db: Database
    ) throws {
        let horizon = Int(now.addingTimeInterval(-max(retention, 0)).timeIntervalSince1970)
        try db.execute(
            sql: "DELETE FROM process_presence WHERE day < ?",
            arguments: [horizon / 86400]
        )
        try db.execute(
            sql: "DELETE FROM process_inventory WHERE last_seen < ?",
            arguments: [horizon]
        )
        // And a surviving row's `first_seen` is dragged forward with the
        // horizon. Without this one timestamp a name outlives the retention it
        // was recorded under — "first run on 12 June" is still a fact about the
        // user months after they asked for a week.
        try db.execute(
            sql: "UPDATE process_inventory SET first_seen = ? WHERE first_seen < ?",
            arguments: [horizon, horizon]
        )
    }

    /// Without this the name table grows forever: retention deletes the rows,
    /// but the interned name outlives them.
    private func collectProcessNames(in db: Database) throws {
        let referenced =
            (ProcessTier.allCases.map { "SELECT name_id FROM \($0.tableName)" }
            + ["SELECT name_id FROM process_inventory", "SELECT name_id FROM process_presence"])
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
