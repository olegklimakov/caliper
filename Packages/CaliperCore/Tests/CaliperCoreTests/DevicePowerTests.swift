import Darwin
import Foundation
import Testing

@testable import CaliperCore

// MARK: - The accelerator itself

/// Serialized, and for a reason worth stating: the degradation case flips a
/// process-wide environment variable, and run in parallel it made the two live
/// tests beside it fail as "this machine has no accelerator".
@Suite(.serialized) struct DeviceGPUAvailability {
    @Test func theAcceleratorReportsAUtilisationAndAMemoryPair() throws {
        let sampler = DeviceGPUSampler()
        // A Mac whose accelerator does not name these hides the reading; that
        // is a pass, the rule the per-process sweep already follows.
        guard sampler.isAvailable else { return }
        let sample = try #require(sampler.sample())

        // Fractions, not the whole percent the accelerator publishes.
        #expect(sample.utilisation >= 0 && sample.utilisation <= 1)
        #expect(sample.rendererUtilisation >= 0 && sample.rendererUtilisation <= 1)
        #expect(sample.tilerUtilisation >= 0 && sample.tilerUtilisation <= 1)
        // The reservation is the larger of the two, always — reading them the
        // other way round is what would make "GPU memory used" report three
        // gigabytes on an idle machine.
        #expect(sample.memoryInUse <= sample.memoryAllocated)
        #expect(sample.memoryAllocated > 0)
        // A GPU that has never reset is the normal machine; a negative count
        // would mean the key held something else.
        #expect(sample.recoveryCount >= 0)
        if let cores = sample.coreCount {
            #expect(cores > 0)
        }
    }

    @Test func theAcceleratorReadingIsInstantaneousRatherThanCumulative() throws {
        let sampler = DeviceGPUSampler()
        guard sampler.isAvailable else { return }
        // Two reads a moment apart. A cumulative counter could only rise; this
        // one is a live utilisation, which is what lets it be sampled with no
        // baseline and no delta — and what would break silently if a future OS
        // changed it to a total.
        let first = try #require(sampler.sample())
        usleep(200_000)
        let second = try #require(sampler.sample())
        #expect(second.sampledAt > first.sampledAt)
        #expect(second.utilisation <= 1)
    }

    @Test func theAcceleratorIsAbsentRatherThanZeroWhenRefused() {
        setenv(GPUPolicy.environmentKey, "1", 1)
        defer { unsetenv(GPUPolicy.environmentKey) }

        let sampler = DeviceGPUSampler()
        #expect(!sampler.isAvailable)
        // Not a sample of zeroes: a GPU at 0 % is a real reading about an idle
        // machine, and a Mac that cannot be read has to be told apart from one.
        #expect(sampler.sample() == nil)
    }
}

// MARK: - Power

@Test func theBatteryReadsAsAChargeCyclesAndACapacityPair() throws {
    let sample = PowerSampler().sample()
    let battery = try #require(sample.battery, "this machine reports no battery")

    #expect(battery.charge > 0 && battery.charge <= 1)
    #expect(battery.cycleCount >= 0)
    #expect(battery.designCapacity > 0)
    #expect(battery.maximumCapacity > 0)
    // Health is the ratio, unclamped, and on a new battery it exceeds one:
    // measured 6324 mA·h against a design 6249 here, which is 101.2 %.
    #expect(battery.health > 0.5)
    #expect(battery.displayedHealth <= 1)
    #expect(battery.displayedHealth == min(battery.health, 1))
    // Signed the way the hardware signs it, so the sign carries the direction
    // rather than a separate flag having to agree with it.
    if battery.isCharging {
        #expect(battery.watts >= 0)
    } else {
        #expect(battery.watts <= 0)
    }
}

@Test func timeRemainingIsAbsentRatherThanZeroWhenMacOSHasNotDecided() throws {
    let sample = PowerSampler().sample()
    // Whichever it is on this machine right now, it must never be the sentinel
    // itself: -1 and -2 are "unknown" and "unlimited", and either printed as a
    // duration is a lie about minutes.
    if let remaining = sample.battery?.timeRemaining {
        #expect(remaining > 0)
    }
}

@Test func aChargingBatteryIsOnMainsAndAnAdapterIsNotInvented() throws {
    let sample = PowerSampler().sample()
    // The adapter is nil when nothing is plugged in — `AdapterDetails` is
    // `{ FamilyCode = 0 }` with no `Watts` key there, not a zero.
    if let watts = sample.adapterWatts {
        #expect(watts > 0)
        #expect(sample.isOnMains)
    }
    if sample.battery?.isCharging == true {
        #expect(sample.isOnMains)
    }
}

@Test func aMachineWithNoBatteryIsADesktopAndNotAFailure() {
    // The shape the sampler must produce on a Mac mini: a sample, with no
    // battery in it. Asserted against the type rather than the hardware,
    // because the hardware to prove it on is a different machine.
    let desktop = PowerSample(
        sampledAt: Date(),
        battery: nil,
        adapterWatts: nil,
        isLowPowerMode: false
    )
    #expect(desktop.battery == nil)
    #expect(!desktop.isOnMains)
}


/// Both new readers copy CF dictionaries out of the kernel, and the device one
/// does it on every tick the app is awake. An unbalanced retain there is a
/// megabyte a minute, which is what the steady-state gate is for — this is the
/// cheaper place to catch it.
@Suite(.serialized) struct DeviceAndPowerFootprint {
    @Test func theAcceleratorReadDoesNotGrowTheFootprint() {
        let sampler = DeviceGPUSampler()
        guard sampler.isAvailable else { return }
        let growth = footprintGrowth(under: 2 * 1_048_576) {
            for _ in 0..<2_000 { _ = sampler.sample() }
        }
        #expect(growth < 2 * 1_048_576, "two thousand accelerator reads grew \(growth) bytes")
    }

    @Test func thePowerReadDoesNotGrowTheFootprint() {
        let sampler = PowerSampler()
        let growth = footprintGrowth(under: 2 * 1_048_576) {
            for _ in 0..<2_000 { _ = sampler.sample() }
        }
        #expect(growth < 2 * 1_048_576, "two thousand power reads grew \(growth) bytes")
    }
}
