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

    public init(pid: Int32, name: String, cpu: Double, memoryFootprint: UInt64, diskRate: Double) {
        self.pid = pid
        self.name = name
        self.cpu = cpu
        self.memoryFootprint = memoryFootprint
        self.diskRate = diskRate
    }
}

/// The processes worth showing, which is never all of them.
public struct ProcessesSample: Sendable, Codable, Equatable {
    /// When this sweep was taken.
    ///
    /// A snapshot carries the newest value of every metric rather than only
    /// what was read on its own tick, so the same process sweep is delivered
    /// again every second until the next one — up to thirty times when the app
    /// is hidden. Anything folding these readings into an average has to be
    /// able to tell a new one from the same one repeated, and only the sampler
    /// knows which it handed out.
    public let sampledAt: Date
    public let topByCPU: [ProcessSample]
    public let topByMemory: [ProcessSample]
    public let topByDisk: [ProcessSample]

    /// Public because a sweep is something other modules build, not only read:
    /// the preview harness feeds synthetic ones through the real recorder, and
    /// the history tests build them to prove the folding is right.
    public init(
        sampledAt: Date,
        topByCPU: [ProcessSample],
        topByMemory: [ProcessSample],
        topByDisk: [ProcessSample]
    ) {
        self.sampledAt = sampledAt
        self.topByCPU = topByCPU
        self.topByMemory = topByMemory
        self.topByDisk = topByDisk
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
}
