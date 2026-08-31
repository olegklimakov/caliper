import Foundation
import GRDB

/// Answers the dashboard's questions: one series, one span, already at a
/// resolution a chart can draw.
///
/// Reads run off the caller's thread through GRDB's async interface — a year of
/// history is a table scan, and the main thread has a window to keep responsive.
public struct HistoryReader: Sendable {
    private let store: HistoryStore

    public init(store: HistoryStore) {
        self.store = store
    }

    /// The last `span` of several series, from the coarsest tier that still has
    /// the detail. Empty when nothing has been recorded.
    ///
    /// One tier for all of them, which is what makes a shared cursor possible:
    /// same width, same alignment, so one instant picks out one row in each.
    public func slice(
        _ series: [MetricSeries],
        span: TimeInterval,
        now: Date = Date()
    ) async throws -> HistorySlice {
        let tier = HistoryStore.tier(forRange: span)
        let start = now.addingTimeInterval(-span)

        return try await store.databaseQueue.read { db in
            try HistoryStore.fetch(series, tier: tier, from: start, to: now, in: db)
        }
    }

    /// The processes stored for the bucket holding one moment. One bucket
    /// rather than a span: a span read is tens of thousands of rows to show
    /// twenty.
    ///
    /// `nil` and an empty bucket are different answers — `nil` is "no tier keeps
    /// that moment", empty is "kept, and holds nothing": asleep, or recording
    /// switched off.
    public func consumers(
        at moment: Date,
        retention: ProcessRetention,
        isRecording: Bool = true,
        now: Date = Date()
    ) async throws -> ProcessBucket? {
        guard let tier = ProcessTier.holding(moment, retention: retention.seconds, now: now) else { return nil }
        return try await store.consumers(at: moment, tier: tier, now: now, isRecording: isRecording)
    }

    /// One name's buckets over the last `span` — the card's history strip.
    /// Sparse by design; an unknown name is an empty history, not an error.
    public func processHistory(
        name: String,
        span: TimeInterval,
        now: Date = Date()
    ) async throws -> ProcessNameHistory {
        // The fine tier keeps a day at most; anything finer-grained than an
        // hour of it reads better at thirty seconds, everything longer at a
        // minute.
        let tier: ProcessTier = span <= 3600 ? .thirtySeconds : .minute
        let start = now.addingTimeInterval(-span)
        return try await store.databaseQueue.read { db in
            try HistoryStore.fetchProcessHistory(name: name, tier: tier, from: start, to: now, in: db)
        }
    }

    /// Joules one name drew over the last `span`.
    ///
    /// The same tier rule as the strip, and the same caveat with teeth: for an
    /// unpinned process this is the energy of the buckets it *ranked* in, which
    /// is a floor. `ProcessEnergy.coveredSeconds` against the span is what says
    /// how much of a floor.
    public func processEnergy(
        name: String,
        span: TimeInterval,
        now: Date = Date()
    ) async throws -> ProcessEnergy {
        let tier: ProcessTier = span <= 3600 ? .thirtySeconds : .minute
        let start = now.addingTimeInterval(-span)
        return try await store.databaseQueue.read { db in
            try HistoryStore.fetchEnergy(name: name, tier: tier, from: start, to: now, in: db)
        }
    }

    /// What drew the most energy over the last `span`, heaviest first — the
    /// battery question, which CPU order does not answer: an efficiency-cluster
    /// process at 200 % costs less than a performance-cluster one at 80 %.
    public func topByEnergy(
        span: TimeInterval,
        limit: Int = ProcessTier.topCount,
        now: Date = Date()
    ) async throws -> [(name: String, joules: Double)] {
        let tier: ProcessTier = span <= 3600 ? .thirtySeconds : .minute
        let start = now.addingTimeInterval(-span)
        return try await store.databaseQueue.read { db in
            try HistoryStore.fetchTopByEnergy(tier: tier, from: start, to: now, limit: limit, in: db)
        }
    }

    /// When a name was first and last seen, for every name the machine has
    /// run — not only the ones that ranked. `nil` means never recorded.
    public func appearance(name: String) async throws -> ProcessAppearance? {
        try await store.databaseQueue.read { db in
            try HistoryStore.fetchAppearance(name: name, in: db)
        }
    }

    /// Removes every stored process row and every interned name. Off the
    /// caller's thread: two table-wide deletes and a vacuum, from a settings
    /// window.
    public func deleteProcessHistory() async throws {
        try await store.deleteProcessHistory()
    }

    /// Removes everything recorded and rebuilds the file at its new size. Off
    /// the caller's thread: a vacuum rewrites the whole file.
    public func deleteAll() async throws {
        try await store.deleteEverything()
    }

    /// Size on disk, counting the write-ahead log and its index.
    ///
    /// Under WAL most of a recording session lives in `history.sqlite-wal` until
    /// something checkpoints it, so the database file alone reads as four
    /// kilobytes on a store holding a day of samples.
    public func storeSize() -> UInt64 {
        let path = store.databaseQueue.path
        return ["", "-wal", "-shm"].reduce(into: UInt64(0)) { total, suffix in
            let attributes = try? FileManager.default.attributesOfItem(atPath: path + suffix)
            total += (attributes?[.size] as? UInt64) ?? 0
        }
    }
}

/// How long a range covers, as the dashboard offers it.
public enum HistorySpan: String, CaseIterable, Sendable, Identifiable {
    case hour
    case day
    case week
    case month
    case year

    public var id: String { rawValue }

    public var seconds: TimeInterval {
        switch self {
        case .hour: 3600
        case .day: 24 * 3600
        case .week: 7 * 24 * 3600
        case .month: 30 * 24 * 3600
        case .year: 365 * 24 * 3600
        }
    }

    public var label: String {
        switch self {
        case .hour: "1H"
        case .day: "24H"
        case .week: "7D"
        case .month: "30D"
        case .year: "1Y"
        }
    }

    public var title: String {
        switch self {
        case .hour: "last hour"
        case .day: "last 24 hours"
        case .week: "last 7 days"
        case .month: "last 30 days"
        case .year: "last year"
        }
    }
}
