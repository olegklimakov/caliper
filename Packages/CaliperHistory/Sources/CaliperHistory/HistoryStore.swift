import Foundation
import GRDB

/// Reads and writes the tiered sample tables.
///
/// Every write is an upsert on (series, bucket): a bucket that is flushed
/// twice — because the app was quit and relaunched inside the same ten seconds
/// — must not become two rows, and the second write is the more complete one.
public struct HistoryStore: Sendable {
    private let queue: DatabaseQueue

    public init(queue: DatabaseQueue) {
        self.queue = queue
    }

    public init(url: URL? = nil) throws {
        self.init(queue: try HistoryDatabase.open(at: url ?? HistoryDatabase.defaultURL()))
    }

    // MARK: - Writing

    public func write(_ samples: [HistorySample], tier: HistoryTier) throws {
        guard !samples.isEmpty else { return }

        try queue.write { db in
            for sample in samples {
                try Self.upsert(sample, tier: tier, in: db)
            }
        }
    }

    private static func upsert(_ sample: HistorySample, tier: HistoryTier, in db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO \(tier.tableName) (series, timestamp, minimum, average, maximum, count)
                VALUES (?, ?, ?, ?, ?, ?)
                ON CONFLICT (series, timestamp) DO UPDATE SET \(Self.mergeClause)
                """,
            arguments: [
                sample.series.rawValue,
                Int(sample.timestamp.timeIntervalSince1970),
                sample.aggregate.minimum,
                sample.aggregate.average,
                sample.aggregate.maximum,
                sample.aggregate.count,
            ]
        )
    }

    /// How two aggregates of the same bucket combine.
    ///
    /// Extremes widen; the average is re-weighted by sample count, which is the
    /// only way to merge two means correctly. Written once because the recorder
    /// and the downsampler must agree — a bucket written twice and a bucket
    /// rolled up twice have to land on the same number.
    static let mergeClause = """
        minimum = min(minimum, excluded.minimum),
        maximum = max(maximum, excluded.maximum),
        average = (average * count + excluded.average * excluded.count)
                  / (count + excluded.count),
        count = count + excluded.count
        """

    // MARK: - Process history

    /// Writes one batch of process rows, interning their names.
    ///
    /// Interning is two statements per name, memoised for the batch and no
    /// longer: a cache that outlived the transaction would have to be
    /// invalidated when the settings button empties the name table.
    func write(processes rows: [ProcessRow], tier: ProcessTier) throws {
        guard !rows.isEmpty else { return }

        try queue.write { db in
            var ids: [String: Int64] = [:]
            for row in rows {
                let id: Int64
                if let known = ids[row.name] {
                    id = known
                } else {
                    id = try Self.intern(row.name, in: db)
                    ids[row.name] = id
                }
                try db.execute(
                    sql: """
                        INSERT INTO \(tier.tableName)
                            (timestamp, name_id, cpu_permille, footprint_mb, disk_kbps, count)
                        VALUES (?, ?, ?, ?, ?, ?)
                        ON CONFLICT (timestamp, name_id) DO UPDATE SET \(Self.processMergeClause)
                        """,
                    arguments: [
                        Int(row.timestamp.timeIntervalSince1970),
                        id,
                        row.cpuPermille,
                        row.footprintMB,
                        row.diskKBps,
                        row.count,
                    ]
                )
            }
        }
    }

    /// The same rule as `mergeClause`, for the same reason. Footprint is a
    /// peak, so it widens rather than being re-weighted.
    static let processMergeClause = """
        cpu_permille = (cpu_permille * count + excluded.cpu_permille * excluded.count)
                       / (count + excluded.count),
        footprint_mb = max(footprint_mb, excluded.footprint_mb),
        disk_kbps = (disk_kbps * count + excluded.disk_kbps * excluded.count)
                    / (count + excluded.count),
        count = count + excluded.count
        """

    private static func intern(_ name: String, in db: Database) throws -> Int64 {
        try db.execute(
            sql: "INSERT INTO process_names (name) VALUES (?) ON CONFLICT (name) DO NOTHING",
            arguments: [name]
        )
        // Not `lastInsertedRowID`: the insert above is a no-op for a name that
        // is already interned, and the id would then be whatever was written
        // last.
        guard let id = try Int64.fetchOne(db, sql: "SELECT id FROM process_names WHERE name = ?", arguments: [name])
        else { throw DatabaseError(message: "process name \(name) was not interned") }
        return id
    }

    /// One bucket, never a span: a day of the finest tier is around sixty
    /// thousand rows and the readout shows twenty.
    func consumers(
        at moment: Date,
        tier: ProcessTier,
        now: Date = Date(),
        isRecording: Bool = true
    ) async throws -> ProcessBucket {
        try await queue.read { db in
            try Self.fetchConsumers(at: moment, tier: tier, now: now, isRecording: isRecording, in: db)
        }
    }

    /// How far back a moment may reach for the bucket that answers it.
    ///
    /// The bucket a moment falls inside is usually not on disk yet: the process
    /// recorder writes on a flush a minute apart, while the ten-second metric
    /// table is seconds behind the clock. So a cursor on the newest metric
    /// bucket asks the process table for a bucket still in memory.
    ///
    /// One flush interval, asked of the writer rather than restated. With the
    /// bucket still filling, that is the furthest the writer can be behind;
    /// past it the answer would be about a different moment.
    static func fetchConsumers(
        at moment: Date,
        tier: ProcessTier,
        now: Date,
        isRecording: Bool,
        in db: Database
    ) throws -> ProcessBucket {
        let asked = tier.bucketStart(of: moment)
        // Reaching back covers one case only: the bucket the writer has not
        // caught up with. A bucket old enough to have been written and still
        // empty means the Mac was asleep, and answering it with readings from
        // ninety seconds earlier would put processes beside a metric row
        // reading "—". Nor is an empty bucket lag while nothing is recording —
        // the recorder discards its open bucket when the setting goes off, so
        // the reader is told whether anyone is writing rather than guessing.
        let reach = Double(tier.seconds) + ProcessTier.flushInterval
        let mayBeLagging = isRecording && now.timeIntervalSince(asked) <= reach
        let earliest = mayBeLagging ? asked.addingTimeInterval(-reach) : asked
        // Read as the integer it is stored as: timestamps go in as seconds
        // since the epoch, and asking for a `Date` lets the driver guess.
        let found = try Int.fetchOne(
            db,
            sql: """
                SELECT MAX(timestamp) FROM \(tier.tableName)
                WHERE timestamp <= ? AND timestamp >= ?
                """,
            arguments: [Int(asked.timeIntervalSince1970), Int(earliest.timeIntervalSince1970)]
        )
        let start = found.map { Date(timeIntervalSince1970: TimeInterval($0)) } ?? asked
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT name, cpu_permille, footprint_mb, disk_kbps
                FROM \(tier.tableName)
                JOIN process_names ON process_names.id = \(tier.tableName).name_id
                WHERE timestamp = ?
                ORDER BY cpu_permille DESC, name
                """,
            arguments: [Int(start.timeIntervalSince1970)]
        )
        return ProcessBucket(
            tier: tier,
            start: start,
            consumers: rows.map { row in
                ProcessUsage(
                    name: row["name"],
                    cpu: Double(row["cpu_permille"] as Int) / 1000,
                    footprint: UInt64(row["footprint_mb"] as Int) * 1_048_576,
                    diskRate: Double(row["disk_kbps"] as Int) * 1024
                )
            }
        )
    }

    /// The settings button behind "a behavioural record you can take back".
    func deleteProcessHistory() async throws {
        try await queue.write { db in
            try Self.deleteProcessHistory(in: db)
        }
    }

    /// Removes everything the app has recorded and hands the space back to the
    /// filesystem.
    ///
    /// Keep it as one implementation. The order — deletes inside a transaction,
    /// reclaim outside one — is the load-bearing part, and a second copy that
    /// shares the SQL but not the order looks correct and is not.
    public func deleteEverything() async throws {
        try await queue.write { db in
            try Self.deleteEverything(in: db)
        }
        try await queue.writeWithoutTransaction { db in
            try Self.reclaimSpace(in: db)
        }
    }

    /// Shared by the blocking and the async callers, so there is one delete.
    static func deleteEverything(in db: Database) throws {
        for tier in HistoryTier.allCases {
            try db.execute(sql: "DELETE FROM \(tier.tableName)")
        }
        for tier in ProcessTier.allCases {
            try db.execute(sql: "DELETE FROM \(tier.tableName)")
        }
        try db.execute(sql: "DELETE FROM process_names")
    }

    /// Rewrites the file at the size its remaining contents need.
    ///
    /// A full `VACUUM`, not the `incremental_vacuum` the process delete uses:
    /// someone clearing everything is asking for the file to stop being that
    /// size. It takes a long lock over the whole file, which is why it is a
    /// separate operation rather than a wider `DELETE`.
    ///
    /// Then a truncating checkpoint, or the claim is invisible — under WAL the
    /// deleted rows live on in `history.sqlite-wal`. Both statements must run
    /// outside a transaction; SQLite refuses them inside one.
    static func reclaimSpace(in db: Database) throws {
        try db.execute(sql: "VACUUM")
        try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
    }

    /// Shared by the blocking and the async callers, so there is one delete.
    static func deleteProcessHistory(in db: Database) throws {
        for tier in ProcessTier.allCases {
            try db.execute(sql: "DELETE FROM \(tier.tableName)")
        }
        try db.execute(sql: "DELETE FROM process_names")
        // Or the file stays the size of the record just deleted.
        try db.execute(sql: "PRAGMA incremental_vacuum(4096)")
    }

    func processRowCount(tier: ProcessTier) throws -> Int {
        try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM \(tier.tableName)") ?? 0
        }
    }

    /// What the name garbage collector is measured by.
    func internedNameCount() throws -> Int {
        try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM process_names") ?? 0
        }
    }

    // MARK: - Reading

    /// Samples of one series over a range, oldest first.
    public func samples(
        _ series: MetricSeries,
        tier: HistoryTier,
        from start: Date,
        to end: Date = Date()
    ) throws -> [HistorySample] {
        try slice([series], tier: tier, from: start, to: end)[series]
    }

    /// Several series over a range, all from one tier.
    public func slice(
        _ series: [MetricSeries],
        tier: HistoryTier,
        from start: Date,
        to end: Date = Date()
    ) throws -> HistorySlice {
        try queue.read { db in
            try Self.fetch(series, tier: tier, from: start, to: end, in: db)
        }
    }

    /// Shared by the blocking and the async readers, so there is one query.
    ///
    /// One statement for all the series: they share the range and largely the
    /// same pages, and a span boundary crossed between separate reads would
    /// hand the caller two tiers that no longer line up. Ordered by
    /// `(series, timestamp)` — the primary key's own order — so SQLite sorts
    /// nothing and each group arrives oldest-first.
    static func fetch(
        _ series: [MetricSeries],
        tier: HistoryTier,
        from start: Date,
        to end: Date,
        in db: Database
    ) throws -> HistorySlice {
        guard !series.isEmpty else {
            return HistorySlice(tier: tier, start: start, end: end, rows: [:])
        }

        let placeholders = Array(repeating: "?", count: series.count).joined(separator: ", ")
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT series, timestamp, minimum, average, maximum, count
                FROM \(tier.tableName)
                WHERE series IN (\(placeholders)) AND timestamp >= ? AND timestamp <= ?
                ORDER BY series, timestamp
                """,
            arguments: StatementArguments(
                series.map { $0.rawValue as any DatabaseValueConvertible }
                    + [
                        Int(start.timeIntervalSince1970),
                        Int(end.timeIntervalSince1970),
                    ]
            )
        )

        var grouped: [MetricSeries: [HistorySample]] = [:]
        for row in rows {
            // The store outlives any one version of the enum.
            guard let name: String = row["series"],
                let series = MetricSeries(rawValue: name)
            else { continue }

            grouped[series, default: []].append(
                HistorySample(
                    series: series,
                    timestamp: Date(timeIntervalSince1970: TimeInterval(row["timestamp"] as Int)),
                    aggregate: Aggregate(
                        minimum: row["minimum"],
                        average: row["average"],
                        maximum: row["maximum"],
                        count: row["count"]
                    )
                )
            )
        }
        return HistorySlice(tier: tier, start: start, end: end, rows: grouped)
    }

    /// The tier that answers a range without handing back more points than a
    /// chart can draw — a year at ten-second resolution is three million rows
    /// for eight hundred pixels.
    public static func tier(forRange seconds: TimeInterval, targetPoints: Int = 600) -> HistoryTier {
        let wanted = seconds / Double(max(targetPoints, 1))
        // The finest tier that still keeps the point count near the target —
        // and when even the coarsest is too fine, the coarsest, because there
        // is nothing better to offer.
        return HistoryTier.allCases.first { Double($0.seconds) >= wanted } ?? .hour
    }

    public func rowCount(tier: HistoryTier) throws -> Int {
        try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM \(tier.tableName)") ?? 0
        }
    }

    var databaseQueue: DatabaseQueue { queue }
}
