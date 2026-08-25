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
    /// the detail. Empty when nothing has been recorded yet — a fresh install
    /// has no past, and that is not an error.
    ///
    /// One tier for all of them, which is what makes a shared cursor possible:
    /// the buckets are the same width and aligned the same way, so one instant
    /// picks out one row in each series without any resampling.
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

    /// The processes stored for the bucket holding one moment, or `nil` when
    /// nothing holds it any more.
    ///
    /// One bucket rather than a span, because that is the whole question: the
    /// cursor is standing somewhere and this is what was running there. A span
    /// read would be tens of thousands of rows to show twenty of them.
    ///
    /// `nil` and an empty bucket are different answers. `nil` is "no tier keeps
    /// that moment", which is a fact about retention; empty is "that moment is
    /// kept and holds nothing", which is the Mac having been asleep or the
    /// recording having been switched off at the time.
    public func consumers(
        at moment: Date,
        retention: ProcessRetention,
        isRecording: Bool = true,
        now: Date = Date()
    ) async throws -> ProcessBucket? {
        guard let tier = ProcessTier.holding(moment, retention: retention.seconds, now: now) else { return nil }
        return try await store.consumers(at: moment, tier: tier, now: now, isRecording: isRecording)
    }

    /// Removes every stored process row and every interned name.
    ///
    /// Off the caller's thread like the reads: it is two table-wide deletes and
    /// a vacuum, and the caller is a settings window.
    public func deleteProcessHistory() async throws {
        try await store.deleteProcessHistory()
    }

    /// Removes everything recorded, metric history included, and rebuilds the
    /// file at its new size.
    ///
    /// Off the caller's thread like the reads: a vacuum rewrites the whole file,
    /// and the caller is a settings window.
    public func deleteAll() async throws {
        try await store.deleteEverything()
    }

    /// Size on disk, for the footprint budget and for the settings screen to
    /// answer "what is this costing me".
    /// The write-ahead log and its index count, not just the database file.
    ///
    /// Under WAL most of a recording session lives in `history.sqlite-wal`
    /// until something checkpoints it, so the database file alone reads as four
    /// kilobytes on a store holding a day of samples — a number that would tell
    /// the settings screen nothing and would never move when the history was
    /// cleared.
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
