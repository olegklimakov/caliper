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
    /// Interning is two statements per name — insert-if-absent, then read the
    /// id — memoised for the batch and no longer. A bucket holds at most twenty
    /// names and a batch is a minute's worth, so a lookup a minute costs
    /// nothing; a cache that outlived the transaction would instead have to be
    /// invalidated when the settings button empties the name table underneath
    /// it.
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

    /// How two writes of the same process bucket combine.
    ///
    /// The same rule as `mergeClause`, for the same reason: quitting and
    /// relaunching inside one bucket must leave one row holding both partial
    /// readings, not the second overwriting the first. Footprint is a peak, so
    /// it widens rather than being re-weighted.
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

    /// The processes stored for the bucket holding one moment, heaviest first.
    ///
    /// One bucket, never a span. A day of the finest tier is around sixty
    /// thousand rows and the readout shows at most twenty of them, so the
    /// cursor asks for the row it is standing on rather than the whole range.
    func consumers(at moment: Date, tier: ProcessTier) async throws -> ProcessBucket {
        try await queue.read { db in
            try Self.fetchConsumers(at: moment, tier: tier, in: db)
        }
    }

    static func fetchConsumers(at moment: Date, tier: ProcessTier, in db: Database) throws -> ProcessBucket {
        let start = tier.bucketStart(of: moment)
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

    /// Deletes every stored process row and every interned name.
    ///
    /// The settings button behind "a behavioural record you can take back".
    func deleteProcessHistory() async throws {
        try await queue.write { db in
            try Self.deleteProcessHistory(in: db)
        }
    }

    /// Removes everything the app has recorded — every metric tier as well as
    /// the process history — and hands the space back to the filesystem.
    /// One implementation, and it is the one the app runs.
    ///
    /// There used to be a second copy of this sequence in `HistoryReader`, so
    /// that the delete could be awaited. The extracted statements kept the two
    /// copies' *SQL* in step but not their order, and the order — the deletes
    /// inside a transaction, the reclaim outside one — is the load-bearing
    /// part. Worse, the tests exercised this copy while the app ran the other:
    /// the project's own lesson about a rule written at two call sites, in both
    /// of its halves.
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
    /// A full `VACUUM`, not the `incremental_vacuum` the process delete uses.
    /// That one returns a bounded number of pages, which is right for a delete
    /// the app carries on recording through; someone who asks to clear
    /// everything is asking for the file to stop being that size, and only a
    /// rewrite does that. It is a long lock over the whole file — every read
    /// and write on this queue waits for it — which is why it is a separate
    /// operation rather than the same one with a wider `DELETE`.
    ///
    /// Then a truncating checkpoint, or the claim is invisible: under WAL the
    /// deleted rows live on in `history.sqlite-wal`, which keeps growing, and
    /// the settings screen would report a file that never changed size.
    ///
    /// Must run outside a transaction — SQLite refuses both statements inside
    /// one.
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
        // Hand the pages back rather than leaving a file that is still the size
        // of the record the user just asked to be rid of.
        try db.execute(sql: "PRAGMA incremental_vacuum(4096)")
    }

    func processRowCount(tier: ProcessTier) throws -> Int {
        try queue.read { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM \(tier.tableName)") ?? 0
        }
    }

    /// How many names are interned — what the garbage collector is measured by.
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
    /// One statement for all the series rather than one apiece. They share the
    /// range and, at this tier, largely the same pages, so seven reads would
    /// walk the same b-tree seven times — and a span boundary crossed between
    /// them would hand the caller two tiers that no longer line up. Ordered by
    /// `(series, timestamp)`, which is the primary key's own order, so SQLite
    /// sorts nothing and each group arrives already oldest-first.
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
            // A row naming a series this build no longer has is skipped rather
            // than faulting: the store outlives any one version of the enum.
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

    /// The tier that answers a range without handing the caller more points
    /// than a chart can draw.
    ///
    /// Asking for a year at ten-second resolution would return three million
    /// rows to plot on eight hundred pixels; the coarsest tier that still has
    /// the detail is always the right answer.
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
