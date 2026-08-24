import Foundation

/// How coarse a stored bucket of process usage is.
///
/// A type of its own rather than a reuse of `HistoryTier`. The finest is thirty
/// seconds because that is the cadence the process sweep already runs at when
/// the app is hidden, and a ten-second tier would be two thirds empty rows. And
/// there is no ten-minute or hourly tier because the set of running processes
/// churns: "the top process of an hour last March" is not a fact anyone wants,
/// and two years of it would be most of the file.
public enum ProcessTier: String, Sendable, CaseIterable, Codable {
    case thirtySeconds
    case minute

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

    /// How long rows of this tier live, given what the user chose to keep.
    ///
    /// The fine tier is capped at a day whatever the setting says: it exists to
    /// answer "what was running when this happened last night", and a fortnight
    /// of thirty-second rows would be most of the file. The coarse tier is the
    /// setting itself — that is what the setting is for.
    ///
    /// One function rather than a constant and a clamp at each call site: the
    /// sweep that deletes rows and the read that decides which tier still holds
    /// a moment have to agree, and disagreeing would draw an empty bucket where
    /// the honest answer is "deleted a week ago".
    public func retention(keeping choice: TimeInterval) -> TimeInterval {
        let wanted = max(choice, 0)
        return switch self {
        case .thirtySeconds: min(wanted, 24 * 3600)
        case .minute: wanted
        }
    }

    /// How many processes a bucket keeps, per ranking: ten by CPU unioned with
    /// ten by footprint. Written once because the recorder and the rollup have
    /// to produce the same shape of list.
    public static let topCount = 10

    /// How wide a bucket of this tier is, as a readout writes it.
    public var label: String {
        switch self {
        case .thirtySeconds: "30 s"
        case .minute: "1 min"
        }
    }

    /// The start of the bucket a moment falls in — the same arithmetic
    /// `HistoryTier` uses, so a process bucket and a metric bucket that share a
    /// start really are the same span.
    public func bucketStart(of date: Date) -> Date {
        CaliperHistory.bucketStart(of: date, width: seconds)
    }

    var tableName: String {
        switch self {
        case .thirtySeconds: "processes_30s"
        case .minute: "processes_1m"
        }
    }

    /// The tier that still holds a given moment, or `nil` when nothing does.
    ///
    /// Not the same question `HistoryStore.tier(forRange:)` answers. A chart
    /// picks a tier so it does not draw more points than it has pixels; this
    /// readout asks for exactly one bucket, so the only thing that matters is
    /// which tier has not yet dropped it.
    public static func holding(_ moment: Date, retention: TimeInterval, now: Date = Date()) -> ProcessTier? {
        let age = now.timeIntervalSince(moment)
        // Finest first, and by the same horizons the sweep deletes on.
        return allCases.first { age <= $0.retention(keeping: retention) }
    }
}

/// What one process cost over one bucket.
///
/// SI and unscaled, like every other model in the package — the store's scaled
/// integers are a storage detail and stop at the store's edge.
public struct ProcessUsage: Sendable, Equatable {
    public let name: String
    /// Mean CPU over the bucket as a share of a *single* core, so a process
    /// using four cores reads 4.0 — the same convention `ProcessSample` uses.
    public let cpu: Double
    /// The **peak** footprint over the bucket, in bytes. Peak rather than mean
    /// because the question asked of a memory history is how much a process
    /// took at worst, not what it averaged.
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
/// missing from a bucket means "not in the top ten", not "idle". A line drawn
/// through that gap would be a lie the UI told confidently.
public struct ProcessBucket: Sendable, Equatable {
    public let tier: ProcessTier
    /// Start of the bucket, aligned to the tier's width.
    public let start: Date
    /// Ranked by CPU. The bucket keeps two rankings, and this is one of them.
    public let consumers: [ProcessUsage]

    public init(tier: ProcessTier, start: Date, consumers: [ProcessUsage]) {
        self.tier = tier
        self.start = start
        self.consumers = consumers
    }

    /// The other ranking the bucket was stored for.
    ///
    /// A process can hold gigabytes while using no CPU at all — a browser left
    /// open overnight is the ordinary case — and the recorder keeps the top ten
    /// by footprint precisely so that it is not lost. Reading only
    /// `consumers` shows the CPU list twice over and never those processes,
    /// which is what the readout did until it was pointed out.
    public var byFootprint: [ProcessUsage] {
        consumers.sorted { $0.footprint > $1.footprint }
    }

    public var isEmpty: Bool { consumers.isEmpty }

    /// The span the readout labels itself with: a process sweep is a sample of
    /// a stretch of time, not a reading at an instant.
    public var end: Date { start.addingTimeInterval(TimeInterval(tier.seconds)) }
}

/// One process over one bucket, on its way to the store.
///
/// The scaled integers the tables hold: SQLite varint-encodes a small integer
/// to one or two bytes where a `DOUBLE` always costs eight, and none of the
/// three values needs more than three significant digits.
struct ProcessRow: Sendable, Equatable {
    let name: String
    let timestamp: Date
    let cpuPermille: Int
    let footprintMB: Int
    let diskKBps: Int
    /// How many sweeps the means are over — the same reason `Aggregate` carries
    /// one. Without it a bucket written twice cannot be merged: the mean of two
    /// means is only the true mean when both cover the same number of readings.
    let count: Int
}

/// How long the process history is kept, as the settings offer it.
///
/// Deliberately short options. A per-minute log of which applications ran is a
/// behavioural record, and the whole store is budgeted at 60 MB — a month of it
/// would be most of both.
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
