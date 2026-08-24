import Foundation

/// One coherent reading of the machine.
///
/// Values are stored in SI units and never formatted — presentation belongs to
/// the UI layer. Metrics sample at different cadences, so a snapshot carries
/// the newest value of each rather than only what was read on this tick; `nil`
/// means never sampled or unavailable on this machine.
public struct SystemSnapshot: Sendable, Codable, Equatable {
    public let timestamp: Date
    public let host: HostInfo
    public let cpu: CPUSample?
    public let memory: MemorySample?
    public let network: NetworkSample?
    public let diskActivity: DiskActivitySample?
    public let volumes: [VolumeSample]?
    public let connection: ConnectionSample?
    public let sensors: SensorsSample?
    /// Drive wear and SMART counters, shown with the disk rather than with the
    /// sensors: this one comes from a public API and survives when the private
    /// sensor interfaces do not.
    public let driveHealth: DriveHealth?
    public let processes: ProcessesSample?
    public let selfMetrics: SelfMetrics?

    /// Stable JSON used by `Caliper --selftest` and by accuracy checks against
    /// Activity Monitor / `vm_stat` / `iostat`.
    public func jsonRepresentation() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }
}
