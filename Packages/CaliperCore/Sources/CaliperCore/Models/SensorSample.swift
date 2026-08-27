/// Temperatures and fans.
///
/// Both come from private interfaces that a future macOS may withdraw, and a
/// Mac may have no fans at all, so the whole sample is optional at the snapshot
/// level: absent means "this machine does not report it", never zero. Drive
/// health is deliberately not here — it comes from a public API and belongs to
/// the disk panel.
public struct SensorsSample: Sendable, Codable, Equatable {
    public let temperatures: [TemperatureReading]
    public let fans: [FanReading]

    /// The hottest reading worth showing, or `nil` on a machine that reports
    /// none.
    ///
    /// Here rather than at each place that wants it: which sensors count is a
    /// fact about this type. The calibration reference reads about twenty
    /// degrees above every real one and would pin a badge, a chart and a
    /// recorded series to a number that means nothing.
    public var peakTemperature: Double? {
        temperatures.lazy.filter { $0.group != .calibration }.map(\.celsius).max()
    }

    /// Every reading that describes a place on the board, which is every one
    /// the calibration reference is not.
    public var realTemperatures: [TemperatureReading] {
        temperatures.filter { $0.group != .calibration }
    }
}

public struct TemperatureReading: Sendable, Codable, Equatable {
    /// The sensor's four-character key, e.g. `TN0n`. Stable across boots, and
    /// the only thing that tells apart the several service clients reporting
    /// one physical sensor.
    public let key: String
    /// The machine's own name for it, e.g. "PMU tdie1".
    public let name: String
    public let group: SensorGroup
    public let celsius: Double
}

/// What a sensor is attached to, as far as the machine is willing to say.
public enum SensorGroup: String, Sendable, Codable, CaseIterable {
    case cpuPerformance
    case cpuEfficiency
    case gpu
    /// A die sensor that names no particular block. Apple Silicon from the M5
    /// generation reports fourteen of these as "PMU tdie1…14" with nothing to
    /// distinguish them, so they are shown as what they are rather than
    /// guessed into core clusters.
    case socDie
    case drive
    case battery
    /// A reference used to calibrate the others, not a place on the board.
    /// Excluded from any "hottest sensor" figure — on this machine it reads
    /// twenty degrees above every real one.
    case calibration
    case other
}

public struct FanReading: Sendable, Codable, Equatable {
    public let index: Int
    /// Current speed. Zero is a normal state on a cool Mac, not a failure.
    public let rpm: Double
    /// The limits and the target are `nil` when the SMC does not report them.
    /// Substituting zero would make a fan at 2000 rpm look like it was running
    /// past its maximum.
    public let minimumRPM: Double?
    public let maximumRPM: Double?
    /// What the SMC is currently aiming for.
    public let targetRPM: Double?
}

/// NVMe SMART health of the internal drive.
public struct DriveHealth: Sendable, Codable, Equatable {
    /// `nil` when the drive does not report its temperature. Wear and the
    /// warning flag are the point of this reading and stand on their own.
    public let celsius: Double?
    /// Share of the drive's rated write endurance consumed, 0…1. Can exceed 1
    /// on a well-used drive, which is what the spec says it means.
    public let lifeUsed: Double
    /// Spare blocks left, 0…1, against the threshold the drive considers
    /// critical.
    public let availableSpare: Double
    public let availableSpareThreshold: Double
    public let powerOnHours: UInt64
    public let powerCycles: UInt64
    public let unsafeShutdowns: UInt64
    public let mediaErrors: UInt64
    /// Non-zero means the drive is reporting a fault of its own.
    public let hasCriticalWarning: Bool
}
