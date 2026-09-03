import Foundation

/// GPU time per process, read from each accelerator's user clients.
public struct GPUSample: Sendable, Codable, Equatable {
    /// When this sweep was taken.
    ///
    /// A snapshot carries the newest value of every metric, so the same sweep
    /// arrives again on every tick between GPU sweeps — anything folding these
    /// has to tell a new one from the same one repeated.
    public let sampledAt: Date
    /// Every process with nonzero accumulated GPU time, descending.
    public let processes: [GPUProcessSample]
}

/// One process's share of the accelerator, cumulative.
public struct GPUProcessSample: Sendable, Codable, Equatable {
    public let pid: Int32
    public let name: String
    /// Seconds of GPU time since the process first touched the accelerator —
    /// the same accounting Activity Monitor's "GPU Time" column shows.
    public let gpuTime: Double
}

/// What the accelerator itself is doing, as opposed to who is asking it to.
///
/// The context a per-process GPU time is read against: four seconds of GPU
/// time is a lot on an idle GPU and nothing on a busy one, and only this says
/// which it was.
public struct GPUDeviceSample: Sendable, Codable, Equatable {
    public let sampledAt: Date
    /// 0…1. Instantaneous, not cumulative — the accelerator reports whole
    /// percent and the reading falls to zero when the machine goes quiet, so
    /// there is no baseline to keep and no delta to take.
    public let utilisation: Double
    /// The two halves of the pipe, which diverge: measured together on this
    /// machine, the renderer tracked the device closely while the tiler sat
    /// twenty points below it. Reporting only the total hides which half a
    /// workload is on.
    public let rendererUtilisation: Double
    public let tilerUtilisation: Double
    /// Bytes the accelerator has in use, and bytes it has reserved. The
    /// difference is large — 0.43 GB against 3.18 GB in one read here — and
    /// quoting the reservation as "GPU memory used" is the mistake this pair
    /// exists to stop.
    public let memoryInUse: UInt64
    public let memoryAllocated: UInt64
    /// Cores, from the accelerator's own configuration. nil where it does not
    /// publish one.
    public let coreCount: Int?
    /// How many times the driver has reset the GPU since boot. Zero on a
    /// healthy machine, and a fault nothing else on the Mac surfaces.
    public let recoveryCount: Int

    public init(
        sampledAt: Date,
        utilisation: Double,
        rendererUtilisation: Double,
        tilerUtilisation: Double,
        memoryInUse: UInt64,
        memoryAllocated: UInt64,
        coreCount: Int?,
        recoveryCount: Int
    ) {
        self.sampledAt = sampledAt
        self.utilisation = utilisation
        self.rendererUtilisation = rendererUtilisation
        self.tilerUtilisation = tilerUtilisation
        self.memoryInUse = memoryInUse
        self.memoryAllocated = memoryAllocated
        self.coreCount = coreCount
        self.recoveryCount = recoveryCount
    }
}
