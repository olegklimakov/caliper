import Testing

@testable import CaliperCore

@Test func selfMetricsMeasureRealCPUTime() {
    var sampler = SelfMetricsSampler()
    let start = ContinuousClock.now
    _ = sampler.sample(at: start)

    // Burn a known slice of wall time on this thread. The conversion from mach
    // ticks to nanoseconds is the whole point: without it this reads about 2 %
    // instead of nearly a full core, which is small enough to look plausible.
    let busyUntil = start + .milliseconds(200)
    while ContinuousClock.now < busyUntil {}

    guard let sample = sampler.sample(at: .now) else {
        Issue.record("second sample should produce a reading")
        return
    }
    #expect(sample.cpu > 0.5)
    // Tests run in parallel, so other threads legitimately push this above one
    // core; the ceiling that means something is the machine's core count.
    #expect(sample.cpu < Double(HostInfo.current().logicalCores))
    #expect(sample.memoryFootprint > 0)
}

@Test func processListsAreRankedAndBounded() {
    var sampler = ProcessSampler()
    let start = ContinuousClock.now
    _ = sampler.sample(at: start)

    guard let sample = sampler.sample(at: start + .seconds(1)) else {
        Issue.record("second sample should produce a reading")
        return
    }

    #expect(!sample.topByCPU.isEmpty)
    #expect(sample.topByCPU.count <= 10)
    #expect(sample.topByMemory.count <= 10)
    #expect(sample.topByCPU == sample.topByCPU.sorted { $0.cpu > $1.cpu })
    #expect(sample.topByMemory == sample.topByMemory.sorted { $0.memoryFootprint > $1.memoryFootprint })
    #expect(sample.topByCPU.allSatisfy { !$0.name.isEmpty })
}
