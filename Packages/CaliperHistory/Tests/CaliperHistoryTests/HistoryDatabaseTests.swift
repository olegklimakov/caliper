import Foundation
import GRDB
import Testing

@testable import CaliperHistory

/// A fresh store in a temporary directory, cleaned up with the test.
func withStore(_ body: (HistoryStore) async throws -> Void) async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("Caliper-history-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    try await body(HistoryStore(url: directory.appendingPathComponent("history.sqlite")))
}

@Test func opensForConcurrentTelemetryWrites() async throws {
    try await withStore { store in
        let (journalMode, synchronous) = try store.databaseQueue.read { db in
            try (
                String.fetchOne(db, sql: "PRAGMA journal_mode"),
                Int.fetchOne(db, sql: "PRAGMA synchronous")
            )
        }
        #expect(journalMode == "wal")
        #expect(synchronous == 1)  // NORMAL

        // Without incremental auto-vacuum, retention frees pages inside the
        // file that are never returned to the filesystem.
        let autoVacuum = try store.databaseQueue.read { db in
            try Int.fetchOne(db, sql: "PRAGMA auto_vacuum")
        }
        #expect(autoVacuum == 2)  // incremental
    }
}

@Test func everyTierGetsItsOwnTable() async throws {
    try await withStore { store in
        for tier in HistoryTier.allCases {
            let count = try store.rowCount(tier: tier)
            #expect(count == 0)
        }
    }
}

@Test func writingTheSameBucketTwiceMergesTheTwoWrites() async throws {
    try await withStore { store in
        let bucket = Date(timeIntervalSince1970: 1_700_000_000)
        try store.write(
            [.init(series: .cpu, timestamp: bucket, aggregate: .init(minimum: 0.1, average: 0.2, maximum: 0.3))],
            tier: .tenSeconds
        )
        try store.write(
            [.init(series: .cpu, timestamp: bucket, aggregate: .init(minimum: 0.05, average: 0.4, maximum: 0.9))],
            tier: .tenSeconds
        )

        let samples = try store.samples(.cpu, tier: .tenSeconds, from: .distantPast, to: .distantFuture)
        #expect(samples.count == 1)
        // Extremes widen, and the average is re-weighted by how many readings
        // each write covered rather than the later one simply winning — a
        // relaunch mid-bucket must not discard the fuller half.
        #expect(samples[0].aggregate.minimum == 0.05)
        #expect(samples[0].aggregate.maximum == 0.9)
        #expect(abs(samples[0].aggregate.average - 0.3) < 0.0001)
        #expect(samples[0].aggregate.count == 2)
    }
}

@Test func rangesPickTheFinestTierThatStaysUnderThePointBudget() {
    // An hour at ten-second resolution is 360 points, inside the 600 budget.
    #expect(HistoryStore.tier(forRange: 3600) == .tenSeconds)
    // A day would be 1440 points at minute resolution, so it steps up to ten
    // minutes and 144.
    #expect(HistoryStore.tier(forRange: 24 * 3600) == .tenMinutes)
    #expect(HistoryStore.tier(forRange: 7 * 24 * 3600) == .hour)
    // A year has nothing coarser to offer than the hour tier.
    #expect(HistoryStore.tier(forRange: 365 * 24 * 3600) == .hour)
}
