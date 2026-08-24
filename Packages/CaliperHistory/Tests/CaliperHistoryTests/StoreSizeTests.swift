import Foundation
import GRDB
import Testing

@testable import CaliperHistory

/// A fresh store on disk, kept until the body returns so its size can be read.
private func withStoreOnDisk(_ body: (HistoryStore) async throws -> Void) async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("Caliper-size-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    try await body(HistoryStore(url: directory.appendingPathComponent("history.sqlite")))
}

/// Folds the write-ahead log back into the file, or the measurement misses most
/// of what was just written.
private func megabytesOnDisk(of store: HistoryStore) throws -> Double {
    _ = try store.databaseQueue.writeWithoutTransaction { db in
        try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
    }
    return megabytesReported(by: store)
}

/// What the settings screen would show — no checkpoint first, exactly as the app
/// asks the question.
private func megabytesReported(by store: HistoryStore) -> Double {
    Double(HistoryReader(store: store).storeSize()) / 1_048_576
}

/// PRD §3 budgets the store at roughly 60 MB steady state, and the Phase 3 exit
/// criterion puts a day of the finest tier under 5 MB. Both are claims about
/// bytes on disk, so they are measured rather than reasoned about.
@Test func aDayOfTenSecondSamplesStaysUnderTheBudget() async throws {
    try await withStoreOnDisk { store in
        // A full day: 8640 ten-second buckets for every series.
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let bucketsPerDay = 24 * 3600 / HistoryTier.tenSeconds.seconds
        var samples: [HistorySample] = []
        samples.reserveCapacity(bucketsPerDay * MetricSeries.allCases.count)
        for bucket in 0..<bucketsPerDay {
            let timestamp = start.addingTimeInterval(Double(bucket * HistoryTier.tenSeconds.seconds))
            for series in MetricSeries.allCases {
                samples.append(
                    HistorySample(
                        series: series,
                        timestamp: timestamp,
                        aggregate: Aggregate(
                            minimum: Double(bucket % 97) / 97,
                            average: Double(bucket % 89) / 89,
                            maximum: Double(bucket % 71) / 71
                        )
                    )
                )
            }
        }
        try store.write(samples, tier: .tenSeconds)

        let rows = try store.rowCount(tier: .tenSeconds)
        #expect(rows == bucketsPerDay * MetricSeries.allCases.count)

        let megabytes = try megabytesOnDisk(of: store)
        #expect(megabytes < 5, "a day of ten-second samples took \(megabytes) MB")
        print(
            String(
                format: "SIZE %d rows -> %.2f MB (%.1f bytes/row)", rows, megabytes,
                megabytes * 1_048_576 / Double(rows)))
    }
}

/// Stage B budgets the process history at roughly 10 MB across both tiers, of
/// which a day of the thirty-second tier is ~2.3 MB. The same claim about bytes,
/// measured the same way — and the reason the values are scaled integers and the
/// names are interned rather than repeated 2880 times a day.
@Test func aDayOfProcessBucketsStaysUnderTheBudget() async throws {
    try await withStoreOnDisk { store in
        // A full day of the finest process tier, each bucket holding the top ten
        // by CPU unioned with the top ten by footprint.
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let bucketsPerDay = 24 * 3600 / ProcessTier.thirtySeconds.seconds
        // Real names, at the length the store actually has to carry.
        let names = (0..<20).map { "com.apple.WebKit.WebContent.Instance\($0)" }

        var rows: [ProcessRow] = []
        rows.reserveCapacity(bucketsPerDay * names.count)
        for bucket in 0..<bucketsPerDay {
            let timestamp = start.addingTimeInterval(Double(bucket * ProcessTier.thirtySeconds.seconds))
            for (index, name) in names.enumerated() {
                rows.append(
                    ProcessRow(
                        name: name,
                        timestamp: timestamp,
                        cpuPermille: (bucket + index) % 4000,
                        footprintMB: (bucket + index) % 8192,
                        diskKBps: (bucket + index) % 512,
                        count: 3
                    )
                )
            }
        }
        try store.write(processes: rows, tier: .thirtySeconds)

        let written = try store.processRowCount(tier: .thirtySeconds)
        #expect(written == bucketsPerDay * names.count)
        // Twenty names for 57 600 rows — the whole point of interning them.
        #expect(try store.internedNameCount() == names.count)

        let megabytes = try megabytesOnDisk(of: store)
        #expect(megabytes < 3, "a day of thirty-second process buckets took \(megabytes) MB")
        print(
            String(
                format: "PROCESS SIZE %d rows -> %.2f MB (%.1f bytes/row)", written, megabytes,
                megabytes * 1_048_576 / Double(written)))
    }
}

/// Clearing is the one operation that promises the *file* gets smaller, not
/// just that the rows are gone. `incremental_vacuum` hands back a bounded
/// number of pages and would leave a store of this size looking untouched from
/// the outside, so the claim is measured rather than assumed.
@Test func clearingEverythingGivesTheSpaceBack() async throws {
    try await withStoreOnDisk { store in
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let buckets = 24 * 3600 / HistoryTier.tenSeconds.seconds
        var samples: [HistorySample] = []
        for bucket in 0..<buckets {
            let timestamp = start.addingTimeInterval(Double(bucket * HistoryTier.tenSeconds.seconds))
            for series in MetricSeries.allCases {
                samples.append(
                    HistorySample(series: series, timestamp: timestamp, aggregate: Aggregate(0.5))
                )
            }
        }
        try store.write(samples, tier: .tenSeconds)
        try store.write(
            processes: [
                ProcessRow(name: "Xcode", timestamp: start, cpuPermille: 100, footprintMB: 1, diskKBps: 0, count: 1)
            ],
            tier: .thirtySeconds
        )

        // Asked the way the settings screen asks it, with no checkpoint of its
        // own. The bug this guards against: `storeSize` counted only
        // `history.sqlite`, so a day of samples sitting in the write-ahead log
        // read as four kilobytes and clearing it changed nothing on screen.
        let before = megabytesReported(by: store)
        #expect(before > 1, "a day of samples reported as \(before) MB before anything was cleared")

        try await store.deleteEverything()
        let after = megabytesReported(by: store)

        for tier in HistoryTier.allCases {
            #expect(try store.rowCount(tier: tier) == 0)
        }
        for tier in ProcessTier.allCases {
            #expect(try store.processRowCount(tier: tier) == 0)
        }
        #expect(try store.internedNameCount() == 0)
        #expect(after < before / 10, "cleared \(before) MB and the file still holds \(after) MB")
        print(String(format: "CLEAR %.2f MB -> %.2f MB", before, after))
    }
}
