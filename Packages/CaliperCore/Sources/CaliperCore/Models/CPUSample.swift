/// CPU load over the interval between two ticks.
///
/// Every value is a busy fraction in `0...1` — the share of elapsed core time
/// that was not idle. Percentages are a presentation concern.
public struct CPUSample: Sendable, Codable, Equatable {
    /// Busy fraction across all cores.
    public let total: Double
    /// Busy fraction per logical core, indexed the way `HostInfo.CoreCluster`
    /// core indices point.
    public let cores: [Double]
    /// Busy fraction per cluster, parallel to `HostInfo.coreClusters`. Empty
    /// when the machine's cluster layout is unknown.
    public let clusters: [Double]
    public let loadAverage: LoadAverage

    public struct LoadAverage: Sendable, Codable, Equatable {
        public let oneMinute: Double
        public let fiveMinutes: Double
        public let fifteenMinutes: Double
    }
}
