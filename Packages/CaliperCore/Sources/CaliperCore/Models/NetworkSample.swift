/// Traffic over the interval between two readings of the interface counters,
/// in bytes per second.
///
/// Rates only, no totals: the kernel reports the full 64-bit byte counters to
/// Apple's own binaries and hands everyone else the low 32 bits, so an absolute
/// "since boot" figure would be wrong past the first four gigabytes. Deltas
/// survive that truncation, and long-run totals belong to the history store
/// anyway, which integrates these rates.
public struct NetworkSample: Sendable, Codable, Equatable {
    public let interfaces: [Interface]
    /// Sum across everything but loopback — traffic that actually left the Mac.
    public let downloadRate: Double
    public let uploadRate: Double

    public struct Interface: Sendable, Codable, Equatable {
        public let name: String
        public let isLoopback: Bool
        public let downloadRate: Double
        public let uploadRate: Double
    }
}
