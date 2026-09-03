import Foundation
import IOKit
import IOKit.ps

/// Charge, cycles, health and what the adapter is supplying.
///
/// Two sources, because neither is complete. `IOPSCopyPowerSourcesInfo` is the
/// public one and owns the *displayed* charge — read in the same call on this
/// machine it said 85 % where the registry's raw millamp-hours worked out to
/// 81 %, and 85 is the number in the menu bar, so it is the number here. The
/// registry owns everything IOPS does not carry: cycle count, the capacity
/// pair, the current and voltage a wattage is made of, and the adapter.
///
/// Both together cost **0.121 ms a sample**, measured over fifty of them.
struct PowerSampler {
    func sample() -> PowerSample {
        let sources = Self.readPowerSources()
        let raw = Self.readSmartBattery()

        return PowerSample(
            sampledAt: Date(),
            battery: Self.battery(sources: sources, raw: raw),
            adapterWatts: raw?.adapterWatts,
            // The public flag rather than IOPS's `LPM Active`: same answer,
            // no dictionary walk, and it is the API Apple documents.
            isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
        )
    }

    private static func battery(sources: Sources?, raw: SmartBattery?) -> BatterySample? {
        // A desktop, not a failure: no battery at all means every field below
        // would be an invention.
        guard let sources, sources.isPresent else { return nil }
        let design = raw?.designCapacity ?? 0
        let maximum = raw?.maximumCapacity ?? 0

        return BatterySample(
            charge: sources.charge,
            isCharging: sources.isCharging,
            timeRemaining: sources.timeRemaining,
            watts: raw?.watts ?? 0,
            cycleCount: raw?.cycleCount ?? 0,
            // Zero rather than one where the pair is unreadable: a health of
            // 100 % nobody measured is the more expensive mistake.
            health: design > 0 ? Double(maximum) / Double(design) : 0,
            maximumCapacity: maximum,
            designCapacity: design
        )
    }

    // MARK: - The public source

    private struct Sources {
        let isPresent: Bool
        let charge: Double
        let isCharging: Bool
        let timeRemaining: TimeInterval?
    }

    private static func readPowerSources() -> Sources? {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }

        for source in list {
            guard
                let info = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue()
                    as? [String: Any],
                info[kIOPSTypeKey] as? String == kIOPSInternalBatteryType
            else { continue }

            // Read as a ratio, not as a percentage: IOPS reports these as a
            // percentage out of 100 for an internal battery and in
            // millamp-hours for some external ones, and the ratio is right
            // either way.
            let current = Double(info[kIOPSCurrentCapacityKey] as? Int ?? 0)
            let maximum = Double(info[kIOPSMaxCapacityKey] as? Int ?? 0)

            return Sources(
                isPresent: info[kIOPSIsPresentKey] as? Bool ?? false,
                charge: maximum > 0 ? current / maximum : 0,
                isCharging: info[kIOPSIsChargingKey] as? Bool ?? false,
                timeRemaining: timeRemaining()
            )
        }
        return nil
    }

    /// nil for both of the API's sentinels. "Unknown" is what macOS reports for
    /// minutes after every state change, and "unlimited" is what it reports on
    /// mains — a zero or a huge number in their place would both read as a
    /// measurement.
    private static func timeRemaining() -> TimeInterval? {
        let estimate = IOPSGetTimeRemainingEstimate()
        guard estimate != kIOPSTimeRemainingUnknown, estimate != kIOPSTimeRemainingUnlimited
        else { return nil }
        return estimate
    }

    // MARK: - The registry

    private struct SmartBattery {
        let cycleCount: Int
        let designCapacity: Int
        let maximumCapacity: Int
        let watts: Double
        let adapterWatts: Double?
    }

    private static func readSmartBattery() -> SmartBattery? {
        var found: SmartBattery?
        IORegistry.forEachService(matching: "AppleSmartBattery") { battery in
            guard found == nil else { return }

            func integer(_ key: String) -> Int? {
                (IORegistry.property(battery, key) as? NSNumber)?.intValue
            }

            // Named keys rather than the whole property dictionary: that
            // dictionary carries `BatteryData`, `ChargerData` and an
            // `IOReportLegend`, none of which this reads and all of which
            // would be copied out of the kernel on every sample.
            let milliamps = integer("Amperage") ?? 0
            let millivolts = integer("AppleRawBatteryVoltage") ?? 0

            found = SmartBattery(
                cycleCount: integer("CycleCount") ?? 0,
                designCapacity: integer("DesignCapacity") ?? 0,
                // The raw reading, which is the one that can exceed the
                // design capacity — see `BatterySample.health`.
                maximumCapacity: integer("AppleRawMaxCapacity") ?? 0,
                watts: Double(milliamps) * Double(millivolts) / 1_000_000,
                adapterWatts: adapterWatts(of: battery)
            )
        }
        return found
    }

    /// nil when nothing is plugged in, which is `{ FamilyCode = 0 }` and no
    /// `Watts` key rather than a zero.
    private static func adapterWatts(of battery: io_registry_entry_t) -> Double? {
        guard let details = IORegistry.property(battery, "AdapterDetails") as? [String: Any],
            let watts = (details["Watts"] as? NSNumber)?.doubleValue,
            watts > 0
        else { return nil }
        return watts
    }
}
