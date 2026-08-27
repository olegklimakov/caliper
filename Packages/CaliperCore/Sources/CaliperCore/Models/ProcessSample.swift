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
    /// A snapshot carries the newest value of every metric, not only what was
    /// read on its own tick, so the same sweep arrives again every second — up
    /// to thirty times when hidden. Anything averaging these has to tell a new
    /// one from the same one repeated.
    public let sampledAt: Date
    public let topByCPU: [ProcessSample]
    public let topByMemory: [ProcessSample]
    public let topByDisk: [ProcessSample]

    /// Public because other modules build sweeps, not only read them: the
    /// preview harness and the history tests both do.
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
