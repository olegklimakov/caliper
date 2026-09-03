import Foundation

/// The machine's own power state — what a per-process wattage is read against.
///
/// "This process is drawing 1.85 W" is half a sentence: half of what, and on
/// mains or on a battery that has forty minutes left? Only this says.
public struct PowerSample: Sendable, Codable, Equatable {
    public let sampledAt: Date
    /// nil on a Mac with no battery, which is a desktop and not a failure.
    public let battery: BatterySample?
    /// Watts the adapter is supplying, or nil when nothing is connected.
    ///
    /// **Unverified against hardware.** The machine this was written on has
    /// never been read while plugged in — `AdapterDetails` is
    /// `{ FamilyCode = 0 }` on battery — so the fixture test is the only thing
    /// standing behind the arithmetic.
    public let adapterWatts: Double?
    /// macOS Low Power Mode, which changes what every other number here means.
    public let isLowPowerMode: Bool

    public init(
        sampledAt: Date,
        battery: BatterySample?,
        adapterWatts: Double?,
        isLowPowerMode: Bool
    ) {
        self.sampledAt = sampledAt
        self.battery = battery
        self.adapterWatts = adapterWatts
        self.isLowPowerMode = isLowPowerMode
    }

    public var isOnMains: Bool { adapterWatts != nil || battery?.isCharging == true }
}

public struct BatterySample: Sendable, Codable, Equatable {
    /// Charge as a fraction, 0…1.
    public let charge: Double
    public let isCharging: Bool
    /// Seconds until empty, or until full while charging. nil while macOS is
    /// still working it out — which it reports for minutes after a state
    /// change, and a zero there would read as "empty now".
    public let timeRemaining: TimeInterval?
    /// Watts flowing out of the battery, or into it while charging. Signed:
    /// negative is discharging, the sign the hardware itself uses.
    public let watts: Double
    public let cycleCount: Int
    /// Full-charge capacity against design capacity — the number Settings
    /// calls "Maximum Capacity".
    ///
    /// **Not clamped here, and that is the point.** Measured on a battery three
    /// cycles old: 6324 mA·h against a design 6249, which is 101.2 %. A new
    /// battery really does hold more than its design capacity; macOS shows 100
    /// and hides it. Clamping in the sampler would lose the fact that this
    /// reading has two sources that disagree — `IOPSCopyPowerSourcesInfo`
    /// reports `Max Capacity` as the *percentage* 100, the registry reports
    /// millamp-hours — so the raw pair travels with it and the readout decides.
    public let health: Double
    public let maximumCapacity: Int
    public let designCapacity: Int

    public init(
        charge: Double,
        isCharging: Bool,
        timeRemaining: TimeInterval?,
        watts: Double,
        cycleCount: Int,
        health: Double,
        maximumCapacity: Int,
        designCapacity: Int
    ) {
        self.charge = charge
        self.isCharging = isCharging
        self.timeRemaining = timeRemaining
        self.watts = watts
        self.cycleCount = cycleCount
        self.health = health
        self.maximumCapacity = maximumCapacity
        self.designCapacity = designCapacity
    }

    /// Health as a readout should print it. Above design capacity is a true
    /// reading that looks like a bug, and every other tool on the platform
    /// shows 100 % there.
    public var displayedHealth: Double { min(health, 1) }
}
