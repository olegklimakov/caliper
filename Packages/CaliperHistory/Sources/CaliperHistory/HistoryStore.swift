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
                            (timestamp, name_id, cpu_permille, footprint_mb, disk_kbps,
                             energy_mj, keep, count)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT (timestamp, name_id) DO UPDATE SET \(Self.processMergeClause)
                        """,
                    arguments: [
                        Int(row.timestamp.timeIntervalSince1970),
                        id,
                        row.cpuPermille,
                        row.footprintMB,
                        row.diskKBps,
                        row.energyMJ,
                        row.keep.rawValue,
                        row.count,
                    ]
                )
            }
        }
    }

    /// The same rule as `mergeClause`, for the same reason. Footprint is a
    /// peak, so it widens rather than being re-weighted; energy is a total, so
    /// it adds; and the strongest reason for keeping the row wins, or a merge
    /// would demote a pinned bucket to a ranked one.
    static let processMergeClause = """
        cpu_permille = (cpu_permille * count + excluded.cpu_permille * excluded.count)
                       / (count + excluded.count),
        footprint_mb = max(footprint_mb, excluded.footprint_mb),
        disk_kbps = (disk_kbps * count + excluded.disk_kbps * excluded.count)
                    / (count + excluded.count),
        energy_mj = energy_mj + excluded.energy_mj,
        keep = max(keep, excluded.keep),
        count = count + excluded.count
        """

    /// Writes the registry: one row a name, one a name a day.
    ///
    /// Every readable name, not the ranked twenty — which is affordable
    /// precisely because it is not per bucket, and is the only record that can
    /// answer for a program too cheap to ever rank.
    func write(appearances rows: [ProcessAppearanceRow]) throws {
        guard !rows.isEmpty else { return }

        try queue.write { db in
            for row in rows {
                let id = try Self.intern(row.name, in: db)
                try db.execute(
                    sql: """
                        INSERT INTO process_inventory (name_id, first_seen, last_seen, path)
                        VALUES (?, ?, ?, ?)
                        ON CONFLICT (name_id) DO UPDATE SET
                            first_seen = min(first_seen, excluded.first_seen),
                            last_seen = max(last_seen, excluded.last_seen),
                            path = coalesce(process_inventory.path, excluded.path)
                        """,
                    arguments: [
                        id,
                        Int(row.firstSeen.timeIntervalSince1970),
                        Int(row.lastSeen.timeIntervalSince1970),
                        row.path,
                    ]
                )
                for (day, hours) in row.hours {
                    try db.execute(
                        sql: """
                            INSERT INTO process_presence (name_id, day, hours)
                            VALUES (?, ?, ?)
                            ON CONFLICT (name_id, day) DO UPDATE SET
                                hours = hours | excluded.hours
                            """,
                        arguments: [id, day, hours]
                    )
                }
            }
        }
    }

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
                SELECT name, cpu_permille, footprint_mb, disk_kbps, energy_mj
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
                    diskRate: Double(row["disk_kbps"] as Int) * 1024,
                    energy: Double(row["energy_mj"] as Int) / 1000
                )
            }
        )
    }

    /// One name across a span, for the card's strip.
    static func fetchProcessHistory(
        name: String,
        tier: ProcessTier,
        from start: Date,
        to end: Date,
        in db: Database
    ) throws -> ProcessNameHistory {
        guard
            let id = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM process_names WHERE name = ?",
                arguments: [name]
            )
        else { return ProcessNameHistory(tier: tier, points: []) }

        // `name_id` is the second column of the primary key, so this is a
        // range scan over the span's rows — at most ~57 600 for a day of the
        // fine tier, milliseconds for one card. An index on (name_id,
        // timestamp) would seek instead, and tax every write for it;
        // deliberately not built until something reads names hot.
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT timestamp, cpu_permille, footprint_mb, disk_kbps, energy_mj, keep
                FROM \(tier.tableName)
                WHERE timestamp BETWEEN ? AND ? AND name_id = ?
                ORDER BY timestamp
                """,
            arguments: [
                Int(start.timeIntervalSince1970), Int(end.timeIntervalSince1970), id,
            ]
        )
        return ProcessNameHistory(
            tier: tier,
            points: rows.map { row in
                ProcessNamePoint(
                    bucketStart: Date(timeIntervalSince1970: TimeInterval(row["timestamp"] as Int)),
                    cpu: Double(row["cpu_permille"] as Int) / 1000,
                    footprint: UInt64(row["footprint_mb"] as Int) * 1_048_576,
                    diskRate: Double(row["disk_kbps"] as Int) * 1024,
                    energy: Double(row["energy_mj"] as Int) / 1000,
                    keep: ProcessKeepReason(rawValue: row["keep"] as Int) ?? .ranked
                )
            }
        )
    }

    /// Joules one name drew over a span, and how much of the span is covered.
    ///
    /// A total rather than a series: "how much energy did this cost me today"
    /// is a sum, and the only reason it can be asked at all is that energy is
    /// stored as energy rather than as the watts it was read from.
    static func fetchEnergy(
        name: String,
        tier: ProcessTier,
        from start: Date,
        to end: Date,
        in db: Database
    ) throws -> ProcessEnergy {
        guard
            let id = try Int64.fetchOne(
                db,
                sql: "SELECT id FROM process_names WHERE name = ?",
                arguments: [name]
            ),
            let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT sum(energy_mj) AS energy_mj, count(*) AS buckets
                    FROM \(tier.tableName)
                    WHERE timestamp BETWEEN ? AND ? AND name_id = ?
                    """,
                arguments: [Int(start.timeIntervalSince1970), Int(end.timeIntervalSince1970), id]
            )
        else { return ProcessEnergy(joules: 0, buckets: 0, tier: tier) }

        return ProcessEnergy(
            joules: Double(row["energy_mj"] as Int? ?? 0) / 1000,
            buckets: row["buckets"] as Int,
            tier: tier
        )
    }

    /// The names that drew the most energy over a span.
    static func fetchTopByEnergy(
        tier: ProcessTier,
        from start: Date,
        to end: Date,
        limit: Int,
        in db: Database
    ) throws -> [(name: String, joules: Double)] {
        try Row.fetchAll(
            db,
            sql: """
                SELECT name, sum(energy_mj) AS energy_mj
                FROM \(tier.tableName)
                JOIN process_names ON process_names.id = \(tier.tableName).name_id
                WHERE timestamp BETWEEN ? AND ?
                GROUP BY name_id
                ORDER BY energy_mj DESC
                LIMIT ?
                """,
            arguments: [Int(start.timeIntervalSince1970), Int(end.timeIntervalSince1970), limit]
        )
        .map { (name: $0["name"], joules: Double($0["energy_mj"] as Int) / 1000) }
    }

    /// One name's registry entry, or nil for a name never recorded.
    static func fetchAppearance(name: String, in db: Database) throws -> ProcessAppearance? {
        try Row.fetchOne(
            db,
            sql: """
                SELECT name, path, first_seen, last_seen
                FROM process_inventory
                JOIN process_names ON process_names.id = process_inventory.name_id
                WHERE name = ?
                """,
            arguments: [name]
        )
        .map { row in
            ProcessAppearance(
                name: row["name"],
                path: row["path"],
                firstSeen: Date(timeIntervalSince1970: TimeInterval(row["first_seen"] as Int)),
                lastSeen: Date(timeIntervalSince1970: TimeInterval(row["last_seen"] as Int))
            )
        }
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
        try Self.deleteProcessTables(in: db)
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
        try deleteProcessTables(in: db)
        // Or the file stays the size of the record just deleted.
        try db.execute(sql: "PRAGMA incremental_vacuum(4096)")
    }

    /// Every table the process record lives in. The registry is part of it:
    /// "a behavioural record you can take back" is a lie if the list of every
    /// program the machine has run survives the button.
    private static func deleteProcessTables(in db: Database) throws {
        for tier in ProcessTier.allCases {
            try db.execute(sql: "DELETE FROM \(tier.tableName)")
        }
        try db.execute(sql: "DELETE FROM process_presence")
        try db.execute(sql: "DELETE FROM process_inventory")
        try db.execute(sql: "DELETE FROM process_names")
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
