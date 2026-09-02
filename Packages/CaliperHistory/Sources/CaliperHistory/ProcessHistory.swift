import CaliperCore
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

    /// The registry writes on its own, rarer schedule. It is one statement per
    /// *name* rather than per ranked row — six hundred of them against twenty —
    /// and at the tier's own rate that write alone moved the steady-state CPU
    /// from 0.85 % to 0.97 %, against a 1 % budget. Ten minutes puts it back
    /// and costs only the precision of "last seen", which `flushNow` makes
    /// exact on a clean exit anyway.
    static let registryFlushInterval: TimeInterval = 600

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

    /// Per ranking: ten by CPU, ten by footprint, ten by energy, unioned.
    /// Written once because the recorder and the rollup have to produce the
    /// same shape.
    public static let topCount = 10

    /// How long a name that has fallen out of every ranking keeps being
    /// recorded. Rank churn is what makes a strip a comb: a process drops to
    /// eleventh for one bucket and leaves a hole that reads as "unknown".
    ///
    /// Five minutes rather than ten because the difference was measured on a
    /// working machine, not reasoned about: at ten the sticky rows were 47 % of
    /// the bucket and it held 29.7 names, at five they are 31 % and it holds
    /// 22.0 — for the same ten buckets of dropout cover, which is far more than
    /// churn needs. The tail is names that ranked once and then idled.
    public static let stickiness: TimeInterval = 300

    /// The most names a bucket carries beyond its rankings — the sticky ones
    /// and the pins together. Churn is unbounded in principle; the width of a
    /// bucket is not allowed to be.
    public static let watchLimit = 40

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

    /// The tier a span of history is read at. One home for the threshold: the
    /// strip, its energy total and the caption naming the span all have to
    /// agree, and three copies of `3600` are three chances not to.
    public static func forSpan(_ span: TimeInterval) -> ProcessTier {
        // The fine tier keeps a day at most; anything shorter than an hour of
        // it reads better at thirty seconds, everything longer at a minute.
        span <= 3600 ? .thirtySeconds : .minute
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
    /// Joules over the bucket, from the SoC's own per-process accounting —
    /// the one quantity here that sums rather than averages, which is what
    /// makes "this app drew 34 Wh today" a question with an answer.
    public let energy: Double

    public init(name: String, cpu: Double, footprint: UInt64, diskRate: Double, energy: Double) {
        self.name = name
        self.cpu = cpu
        self.footprint = footprint
        self.diskRate = diskRate
        self.energy = energy
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

/// One name's row in one bucket — a point of the card's history strip.
public struct ProcessNamePoint: Sendable, Equatable {
    public let bucketStart: Date
    public let cpu: Double
    /// Peak bytes over the bucket, the same accounting as `ProcessUsage`.
    public let footprint: UInt64
    public let diskRate: Double
    /// Joules over the bucket, the same accounting as `ProcessUsage`.
    public let energy: Double
    /// Why this bucket was recorded, which decides what a *neighbouring* gap
    /// means: beside a pinned point it is "the process was not running", beside
    /// a ranked one only "it did not rank".
    public let keep: ProcessKeepReason

    public init(
        bucketStart: Date,
        cpu: Double,
        footprint: UInt64,
        diskRate: Double,
        energy: Double,
        keep: ProcessKeepReason
    ) {
        self.bucketStart = bucketStart
        self.cpu = cpu
        self.footprint = footprint
        self.diskRate = diskRate
        self.energy = energy
        self.keep = keep
    }
}

/// One name across a span — the sanctioned series form: sparse, so the gaps
/// stay real. Only the top ten per bucket are stored, and a bucket with no
/// point means "not in the top ten then", not "idle" — which is why this is
/// drawn as bars with holes and never as a line.
public struct ProcessNameHistory: Sendable, Equatable {
    public let tier: ProcessTier
    public let points: [ProcessNamePoint]

    public init(tier: ProcessTier, points: [ProcessNamePoint]) {
        self.tier = tier
        self.points = points
    }
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
    /// Millijoules over the bucket. Summed on merge and on rollup where the
    /// others are re-weighted or maxed, because it is a total.
    let energyMJ: Int
    /// A `var` because the fold decides the reason after ranking the rows it
    /// has already built.
    var keep: ProcessKeepReason
    /// How many sweeps the means are over, for the reason `Aggregate` carries
    /// one.
    let count: Int
}

/// Why a row was written, in the order the rollup resolves ties: a pin is a
/// promise that every bucket is there, and outranks a coincidence of rank.
public enum ProcessKeepReason: Int, Sendable, Comparable {
    case ranked = 0
    case sticky = 1
    case pinned = 2

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// What one name drew over a span.
public struct ProcessEnergy: Sendable, Equatable {
    public let joules: Double
    /// How many buckets carried a row. An unpinned process contributes nothing
    /// for the buckets it did not rank in, so the total is a floor rather than
    /// a measurement of the whole span — and a readout that does not say which
    /// it is has invented a number.
    public let buckets: Int
    public let tier: ProcessTier

    public init(joules: Double, buckets: Int, tier: ProcessTier) {
        self.joules = joules
        self.buckets = buckets
        self.tier = tier
    }

    /// Seconds the total actually accounts for.
    public var coveredSeconds: TimeInterval { Double(buckets * tier.seconds) }
}

/// One name's registry entry as the recorder accumulates it between flushes.
///
/// Days and hours are UTC: the mask is storage, and a readout that wants local
/// time converts. Storing it local would rewrite history twice a year.
struct ProcessAppearanceRow: Sendable, Equatable {
    let name: String
    var path: String?
    var firstSeen: Date
    var lastSeen: Date
    /// Day since the epoch to a bit per hour of that day.
    var hours: [Int: Int]

    init(identity: ProcessIdentity, at moment: Date) {
        name = identity.name
        path = identity.path
        firstSeen = moment
        lastSeen = moment
        hours = [:]
    }

    static func day(of moment: Date) -> Int {
        Int(moment.timeIntervalSince1970) / 86400
    }

    static func hourBit(of moment: Date) -> Int {
        1 << (Int(moment.timeIntervalSince1970) % 86400 / 3600)
    }

    mutating func observe(identity: ProcessIdentity, at moment: Date, day: Int, hour: Int) {
        // A pid whose path was refused this time may be readable the next.
        path = path ?? identity.path
        firstSeen = Swift.min(firstSeen, moment)
        lastSeen = Swift.max(lastSeen, moment)
        hours[day, default: 0] |= hour
    }
}

/// A name the machine has run, and when it was first and last seen.
///
/// Both bounded by the retention the user chose: "first seen on Tuesday" means
/// first seen inside what is kept, and a readout has to say so.
public struct ProcessAppearance: Sendable, Equatable {
    public let name: String
    /// nil when the path was never readable — see `ProcessIdentity.path`.
    public let path: String?
    public let firstSeen: Date
    public let lastSeen: Date

    public init(name: String, path: String?, firstSeen: Date, lastSeen: Date) {
        self.name = name
        self.path = path
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
    }
}

/// What the registry answers a search with.
public struct ProcessNameSearch: Sendable, Equatable {
    /// Most recently seen first, capped at the limit asked for.
    public let matches: [ProcessAppearance]
    /// How many names matched, which `matches` may be only the head of.
    public let matched: Int
    /// Every name the registry holds, matched or not — the size of the record,
    /// which is what says whether an empty result means "no such name" or
    /// "nothing recorded yet".
    public let recorded: Int

    public init(matches: [ProcessAppearance], matched: Int, recorded: Int) {
        self.matches = matches
        self.matched = matched
        self.recorded = recorded
    }
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
