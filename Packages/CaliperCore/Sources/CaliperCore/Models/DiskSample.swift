/// Throughput of the physical storage devices, in bytes per second.
public struct DiskActivitySample: Sendable, Codable, Equatable {
    public let devices: [Device]
    public let readRate: Double
    public let writeRate: Double

    public struct Device: Sendable, Codable, Equatable {
        /// Product name from the IORegistry, e.g. "APPLE SSD AP1024Z".
        public let name: String
        public let readRate: Double
        public let writeRate: Double
        public let bytesRead: UInt64
        public let bytesWritten: UInt64
    }
}

/// A mounted volume and how much of it is left.
public struct VolumeSample: Sendable, Codable, Equatable {
    public let name: String
    public let mountPoint: String
    public let totalCapacity: UInt64
    /// What the system reports as available for important usage — the figure
    /// Finder shows, which counts purgeable space the OS would free up.
    public let availableCapacity: UInt64

    public var usedCapacity: UInt64 { totalCapacity.subtractingClamped(availableCapacity) }
}
