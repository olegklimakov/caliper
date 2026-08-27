import Foundation

/// How coarse a stored bucket of process usage is.
///
/// Its own type rather than a reuse of `HistoryTier`: the finest is thirty
/// seconds, the cadence the process sweep already runs at when hidden, and
/// there is no hourly tier because the set of running processes churns — "the
/// top process of an hour last March" is not a fact anyone wants.
public enum ProcessTier: String, Sendable, CaseIterable, Codable {
    case thirtySeconds
    case minute

    /// One transaction a minute rather than one a tick: a write per sweep is a
    /// disk wakeup per sweep.
    ///
    /// Not private to the recorder — a reader asking for the bucket a cursor is
    /// standing in has to know how far behind the writer is allowed to be, or it
    /// reports an empty bucket for a moment that was recorded.
    public static let flushInterval: TimeInterval = 60

    public var seconds: Int {
        switch self {
        case .thirtySeconds: 30
        case .minute: 60
        }
    }

    /// The tier this one is rolled up from, or `nil` for the finest.
    public var source: ProcessTier? {
        switch self {
        case .thirtySeconds: nil
        case .minute: .thirtySeconds
        }
    }

    /// How long rows of this tier live, given what the user chose to keep. The
    /// fine tier is capped at a day whatever the setting says — a fortnight of
    /// thirty-second rows would be most of the file.
    ///
    /// One function rather than a clamp at each call site: the sweep that
    /// deletes and the read that picks a tier have to agree, or the readout
    /// draws an empty bucket where the honest answer is "deleted a week ago".
    public func retention(keeping choice: TimeInterval) -> TimeInterval {
        let wanted = max(choice, 0)
        return switch self {
        case .thirtySeconds: min(wanted, 24 * 3600)
        case .minute: wanted
        }
    }

    /// Per ranking: ten by CPU unioned with ten by footprint. Written once
    /// because the recorder and the rollup have to produce the same shape.
    public static let topCount = 10

    /// How wide a bucket is, as a readout writes it.
    public var label: String {
        switch self {
        case .thirtySeconds: "30 s"
        case .minute: "1 min"
        }
    }

    /// The same arithmetic `HistoryTier` uses, so a process bucket and a metric
    /// bucket that share a start really are the same span.
    public func bucketStart(of date: Date) -> Date {
        CaliperHistory.bucketStart(of: date, width: seconds)
    }

    var tableName: String {
        switch self {
        case .thirtySeconds: "processes_30s"
        case .minute: "processes_1m"
        }
    }

    /// The tier that still holds a moment, or `nil`. Not the question
    /// `HistoryStore.tier(forRange:)` answers — a chart picks a tier by pixel
    /// budget, this asks only which tier has not yet dropped the bucket.
    public static func holding(_ moment: Date, retention: TimeInterval, now: Date = Date()) -> ProcessTier? {
        let age = now.timeIntervalSince(moment)
        // Finest first, and by the same horizons the sweep deletes on.
        return allCases.first { age <= $0.retention(keeping: retention) }
    }
}

/// What one process cost over one bucket. SI and unscaled — the store's scaled
/// integers stop at the store's edge.
public struct ProcessUsage: Sendable, Equatable {
    public let name: String
    /// Mean CPU as a share of a *single* core, so four cores read 4.0 — the
    /// convention `ProcessSample` uses.
    public let cpu: Double
    /// The **peak** footprint in bytes: what a process took at worst is the
    /// question asked of a memory history, not what it averaged.
    public let footprint: UInt64
    /// Mean bytes per second moved to and from storage.
    public let diskRate: Double

    public init(name: String, cpu: Double, footprint: UInt64, diskRate: Double) {
        self.name = name
        self.cpu = cpu
        self.footprint = footprint
        self.diskRate = diskRate
    }
}

/// The processes stored for one bucket, heaviest first.
///
/// A bucket at a time, never a series: only the top ten are kept, so a process
/// missing from a bucket means "not in the top ten", not "idle", and a line
/// drawn through that gap would be a lie.
public struct ProcessBucket: Sendable, Equatable {
    public let tier: ProcessTier
    /// Start of the bucket, aligned to the tier's width.
    public let start: Date
    /// One of the bucket's two rankings; see `byFootprint` for the other.
    public let consumers: [ProcessUsage]

    public init(tier: ProcessTier, start: Date, consumers: [ProcessUsage]) {
        self.tier = tier
        self.start = start
        self.consumers = consumers
    }

    /// A process can hold gigabytes while using no CPU — a browser left open
    /// overnight — so the recorder keeps a top ten by footprint too. Reading
    /// only `consumers` shows the CPU list twice and never those processes.
    public var byFootprint: [ProcessUsage] {
        consumers.sorted { $0.footprint > $1.footprint }
    }

    public var isEmpty: Bool { consumers.isEmpty }

    /// A process sweep samples a stretch of time, not an instant.
    public var end: Date { start.addingTimeInterval(TimeInterval(tier.seconds)) }
}

/// One process over one bucket, in the scaled integers the tables hold: SQLite
/// varint-encodes a small integer to one or two bytes where a `DOUBLE` always
/// costs eight, and none of the three values needs three significant digits.
struct ProcessRow: Sendable, Equatable {
    let name: String
    let timestamp: Date
    let cpuPermille: Int
    let footprintMB: Int
    let diskKBps: Int
    /// How many sweeps the means are over, for the reason `Aggregate` carries
    /// one.
    let count: Int
}

/// How long the process history is kept. Deliberately short options: a
/// per-minute log of which applications ran is a behavioural record, and the
/// whole store is budgeted at 60 MB.
public enum ProcessRetention: String, CaseIterable, Sendable, Identifiable {
    case day
    case week
    case twoWeeks

    public var id: String { rawValue }

    public var seconds: TimeInterval {
        switch self {
        case .day: 24 * 3600
        case .week: 7 * 24 * 3600
        case .twoWeeks: 14 * 24 * 3600
        }
    }

    public var label: String {
        switch self {
        case .day: "1 day"
        case .week: "7 days"
        case .twoWeeks: "14 days"
        }
    }
}
