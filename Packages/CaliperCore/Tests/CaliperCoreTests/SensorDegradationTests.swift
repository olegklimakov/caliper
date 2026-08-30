import Darwin
import Testing

@testable import CaliperCore

/// Serialized because the degradation case flips a process-wide environment
/// variable: run in parallel, it would quietly turn the hardware tests below
/// into tests of nothing.
@Suite(.serialized)
struct SensorAvailability {
    @Test func temperaturesComeBackDeduplicatedAndPlausible() {
        let sampler = TemperatureSampler()
        // A Mac that reports no sensors hides the feature; that is a pass.
        guard sampler.isAvailable else { return }

        let readings = sampler.sample()
        #expect(!readings.isEmpty)
        #expect(readings.allSatisfy { $0.key.count == 4 })
        #expect(readings.allSatisfy { (-40.0...150.0).contains($0.celsius) })
        // The system reports each physical sensor through several clients; only
        // one of each should survive the probe.
        #expect(Set(readings.map(\.key)).count == readings.count)
    }

    @Test func fansReportPlausibleSpeeds() {
        let sampler = FanSampler()
        // A fanless Mac is a supported machine, not a failure.
        guard sampler.isAvailable else { return }

        let fans = sampler.sample()
        #expect(!fans.isEmpty)
        for fan in fans {
            #expect(fan.rpm >= 0)
            // Limits are optional: a fan that does not report them shows no
            // range rather than a range of zero.
            if let minimum = fan.minimumRPM, let maximum = fan.maximumRPM {
                #expect(maximum > minimum)
                #expect(fan.rpm <= maximum)
            }
        }
    }

    /// Every reading copies Core Foundation objects out of the HID event
    /// system. The shim header claims they follow the create/copy rule; if that
    /// claim were wrong, a sampler running once a second would leak all day.
    @Test func repeatedReadsDoNotLeak() {
        let sampler = TemperatureSampler()
        guard sampler.isAvailable else { return }

        _ = sampler.sample()

        // A full sweep costs about 29 ms, so each round is kept to a few
        // seconds. Twenty-odd sensors two hundred times over: an unbalanced
        // retain would strand thousands of objects, well past this slack.
        let budget: Int64 = 2_000_000
        let growth = footprintGrowth(under: budget) {
            for _ in 0..<200 {
                _ = sampler.sample()
            }
        }
        #expect(growth < budget, "footprint grew by \(growth) bytes")
    }

    /// PRD §6 asks for graceful degradation to be *proven*, not assumed: with
    /// the sensor interfaces stubbed out, the app must run with the feature
    /// hidden rather than reporting zeros.
    @Test func hidesTemperaturesAndFansWhenPrivateInterfacesAreRefused() async {
        setenv(SensorPolicy.environmentKey, "1", 1)
        defer { unsetenv(SensorPolicy.environmentKey) }

        #expect(SensorPolicy.allowsPrivateInterfaces == false)

        let temperatures = TemperatureSampler()
        #expect(temperatures.isAvailable == false)
        #expect(temperatures.sample().isEmpty)

        let fans = FanSampler()
        #expect(fans.isAvailable == false)
        #expect(fans.sample().isEmpty)

        // The whole feature disappears from the snapshot — no empty shell, no
        // zero-degree readings.
        let coordinator = SamplingCoordinator()
        await coordinator.tick()
        await coordinator.tick()
        let snapshot = await coordinator.latestSnapshot()
        #expect(snapshot.sensors == nil)

        // Everything built on public APIs keeps working.
        #expect(snapshot.cpu != nil)
        #expect(snapshot.memory != nil)
    }
}
