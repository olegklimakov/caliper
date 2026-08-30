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
