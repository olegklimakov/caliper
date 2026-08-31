import Foundation

/// What one process is costing right now.
public struct ProcessSample: Sendable, Codable, Equatable {
    public let pid: Int32
    public let name: String
    /// CPU time as a share of a *single* core over the interval, so a process
    /// using four cores reports 4.0 — the same convention Activity Monitor's
    /// "% CPU" column uses.
    public let cpu: Double
    public let memoryFootprint: UInt64
    /// Bytes per second moved to and from storage over the interval.
    public let diskRate: Double
    /// Watts over the interval, from the SoC's own per-process energy
    /// accounting (`ri_energy_nj`) — a real unit checkable against
    /// `powermetrics`, unlike Activity Monitor's unitless "Energy Impact".
    /// CPU-cluster energy only; it does not see the GPU, the display, or the
    /// wall plug.
    public let power: Double
    /// Package-idle plus interrupt wakeups per second — what drains a battery
    /// at low CPU.
    public let wakeupsPerSecond: Double
    /// Of the cycles retired over the interval, the fraction on the
    /// performance clusters; nil when no cycles were retired — a share of
    /// nothing is not 0 %. "Performance" is the kernel's own designation, not
    /// "P/E": cluster names come from the machine, and this M5 Pro has no
    /// "Efficiency" level at all.
    public let performanceCycleShare: Double?
    /// nil when the process reports no QoS accounting — about one in nine
    /// does not — which is absence of data, not 100 % default QoS.
    public let qos: QoSBreakdown?

    public init(
        pid: Int32,
        name: String,
        cpu: Double,
        memoryFootprint: UInt64,
        diskRate: Double,
        power: Double,
        wakeupsPerSecond: Double,
        performanceCycleShare: Double?,
        qos: QoSBreakdown?
    ) {
        self.pid = pid
        self.name = name
        self.cpu = cpu
        self.memoryFootprint = memoryFootprint
        self.diskRate = diskRate
        self.power = power
        self.wakeupsPerSecond = wakeupsPerSecond
        self.performanceCycleShare = performanceCycleShare
        self.qos = qos
    }
}

/// CPU core-share per QoS tier, the same unit as `ProcessSample.cpu`, so the
/// seven roughly decompose it: `background` against `userInteractive` is
/// whether a program serves the person at the keyboard or grinds behind their
/// back.
///
/// Seven tiers rather than a condensed pair, because which side `utility` or
/// `legacy` falls on is presentation policy, not measurement.
public struct QoSBreakdown: Sendable, Codable, Equatable {
    public let userInteractive: Double
    public let userInitiated: Double
    public let defaultTier: Double
    public let legacy: Double
    public let utility: Double
    public let background: Double
    public let maintenance: Double

    public init(
        userInteractive: Double,
        userInitiated: Double,
        defaultTier: Double,
        legacy: Double,
        utility: Double,
        background: Double,
        maintenance: Double
    ) {
        self.userInteractive = userInteractive
        self.userInitiated = userInitiated
        self.defaultTier = defaultTier
        self.legacy = legacy
        self.utility = utility
        self.background = background
        self.maintenance = maintenance
    }
}

/// A name the sweep saw, and where it was launched from.
///
/// All that is recorded about a process that never enters a top list. Cheap
/// enough to keep for every readable pid — one row a name a day rather than
/// one a bucket — and it is the only thing that can answer "this appeared on
/// Tuesday at three in the morning", which a ranked list cannot: a program
/// that wants to go unnoticed is deliberately too cheap to rank.
public struct ProcessIdentity: Sendable, Codable, Equatable, Hashable {
    public let name: String
    /// nil when `proc_pidpath` refused and the name came from `proc_name`.
    public let path: String?

    public init(name: String, path: String?) {
        self.name = name
        self.path = path
    }
}

/// The processes worth showing, which is never all of them.
public struct ProcessesSample: Sendable, Codable, Equatable {
    /// When this sweep was taken.
    ///
    /// A snapshot carries the newest value of every metric, not only what was
    /// read on its own tick, so the same sweep arrives again every second — up
    /// to thirty times when hidden. Anything averaging these has to tell a new
    /// one from the same one repeated.
    public let sampledAt: Date
    /// Seconds the sweep covers — the window every rate here is over. Energy
    /// is `power × interval`, which recovers the `ri_energy_nj` delta the
    /// watts were divided out of; reconstructing it from arrival times would
    /// guess at a gap the sampler already knows the width of.
    public let interval: TimeInterval
    public let topByCPU: [ProcessSample]
    public let topByMemory: [ProcessSample]
    public let topByDisk: [ProcessSample]
    /// Ranked by watts, and only processes that drew any. A separate list
    /// because CPU order is not power order: an efficiency-cluster process at
    /// 200 % CPU can draw less than a performance-cluster one at 80 %.
    public let topByPower: [ProcessSample]
    /// Processes the recorder asked for by name, whatever they rank — pinned
    /// ones and those it is holding on to after they fell out of a list. Per
    /// pid, not per name: forty helpers called "Google Chrome Helper" are
    /// forty readings that sum, and summing is the caller's to do.
    public let watched: [ProcessSample]
    /// Every name this sweep could read, deduped.
    public let roster: [ProcessIdentity]
    /// Pids whose counters the kernel refused — other users' processes, about
    /// a quarter of the machine, plus the few that exited between the pid
    /// sweep and the read. They carry no numbers, so no list can rank them;
    /// the count says how many, because a zero would be a claim.
    public let unreadableCount: Int

    /// Public because other modules build sweeps, not only read them: the
    /// preview harness and the history tests both do.
    public init(
        sampledAt: Date,
        interval: TimeInterval,
        topByCPU: [ProcessSample],
        topByMemory: [ProcessSample],
        topByDisk: [ProcessSample],
        topByPower: [ProcessSample],
        watched: [ProcessSample] = [],
        roster: [ProcessIdentity] = [],
        unreadableCount: Int
    ) {
        self.sampledAt = sampledAt
        self.interval = interval
        self.topByCPU = topByCPU
        self.topByMemory = topByMemory
        self.topByDisk = topByDisk
        self.topByPower = topByPower
        self.watched = watched
        self.roster = roster
        self.unreadableCount = unreadableCount
    }
}

/// What Caliper itself is costing, held to the same standard as everything it
/// measures: under 1 % of one core and under 50 MB.
public struct SelfMetrics: Sendable, Codable, Equatable {
    /// Share of a single core, the same convention as `ProcessSample.cpu` —
    /// not the all-cores fraction `CPUSample.total` uses.
    public let cpu: Double
    public let memoryFootprint: UInt64
    /// Bytes per second moved to and from storage over the interval.
    public let diskRate: Double
    /// Watts over the interval, the same accounting as `ProcessSample.power`.
    public let power: Double
}
