import Foundation

/// Static description of the machine, read once at launch.
public struct HostInfo: Sendable, Codable, Equatable {
    public let model: String
    public let chip: String
    public let logicalCores: Int
    /// Core clusters, fastest first. Empty when the layout could not be
    /// established, in which case cores are reported unlabeled.
    public let coreClusters: [CoreCluster]
    public let physicalMemory: UInt64
    public let operatingSystem: String

    /// One performance level of the CPU, with the logical cores it owns.
    ///
    /// Names come from the machine (`hw.perflevel*.name`) rather than a
    /// performance/efficiency pair: an M5 Pro reports "Super" and "Performance"
    /// and has no efficiency level at all.
    public struct CoreCluster: Sendable, Codable, Equatable {
        public let name: String
        /// Indices into the per-core arrays of `CPUSample`.
        public let coreIndices: [Int]

        public var logicalCores: Int { coreIndices.count }
    }

    public static func current() -> HostInfo {
        let logicalCores =
            Sysctl.value("hw.logicalcpu", as: Int32.self).map(Int.init)
            ?? ProcessInfo.processInfo.processorCount

        return HostInfo(
            model: Sysctl.string("hw.model") ?? "unknown",
            chip: Sysctl.string("machdep.cpu.brand_string") ?? "unknown",
            logicalCores: logicalCores,
            coreClusters: CPUTopology.clusters(logicalCores: logicalCores),
            physicalMemory: Sysctl.value("hw.memsize", as: UInt64.self)
                ?? ProcessInfo.processInfo.physicalMemory,
            operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString
        )
    }
}
