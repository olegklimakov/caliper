import Darwin
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
    // A core spinning for the window has to have drawn real power; a hundred
    // watts is more than this whole SoC can dissipate.
    #expect(sample.power > 0)
    #expect(sample.power < 100)
}

@Test func qosBucketsAreNanosecondsNotTicks() {
    guard let before = ResourceUsage.counters(for: getpid()) else {
        Issue.record("own pid must be readable")
        return
    }
    let start = ContinuousClock.now
    let busyUntil = start + .milliseconds(200)
    while ContinuousClock.now < busyUntil {}
    guard let after = ResourceUsage.counters(for: getpid()) else {
        Issue.record("own pid must be readable")
        return
    }

    // 200 ms of spin lands in *some* QoS bucket; which one depends on the test
    // runner's thread, so only the sum is pinned. Unconverted mach ticks would
    // read the burn as ~4.8 ms — forty-one times low — and fail decisively.
    let qosDelta = after.qosTime.total.subtractingClamped(before.qosTime.total)
    #expect(qosDelta > 100_000_000)

    // Both go through the same conversion; if they ever diverge, one of them
    // stopped being nanoseconds.
    let cpuDelta = after.cpuTime.subtractingClamped(before.cpuTime)
    #expect(Double(qosDelta) < Double(cpuDelta) * 1.5)
}

@Test func countersCarryTheRestOfTheStruct() {
    guard let first = ResourceUsage.counters(for: getpid()),
        let second = ResourceUsage.counters(for: getpid())
    else {
        Issue.record("own pid must be readable")
        return
    }

    #expect(first.energy > 0)
    #expect(first.pEnergy <= first.energy)
    #expect(first.pCycles <= first.cycles)
    #expect(first.instructions > 0)
    #expect(first.startTime != 0)
    // The start time is an identity token; two reads of the same process must
    // agree or pid-reuse detection would invalidate every baseline.
    #expect(first.startTime == second.startTime)
    #expect(first.lifetimeMaxFootprint >= first.physicalFootprint)
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

@Test func sweepCountsWhatItCannotRead() {
    var sampler = ProcessSampler()
    let start = ContinuousClock.now
    _ = sampler.sample(at: start)

    guard let sample = sampler.sample(at: start + .seconds(1)) else {
        Issue.record("second sample should produce a reading")
        return
    }

    // An unprivileged test run cannot read root's processes, and every Mac
    // runs hundreds of them.
    #expect(sample.unreadableCount > 0)
    // No minimum length: over a near-zero real interval most processes draw no
    // measurable energy, and the list keeps only those that did.
    #expect(sample.topByPower == sample.topByPower.sorted { $0.power > $1.power })
    #expect(sample.topByPower.allSatisfy { $0.power > 0 })
    let shares = (sample.topByCPU + sample.topByPower).compactMap(\.performanceCycleShare)
    #expect(shares.allSatisfy { $0 >= 0 && $0 <= 1 })
}

// MARK: - Derivation rules, without live pids

private func syntheticCounters(
    cpuTime: UInt64 = 0,
    energy: UInt64 = 0,
    cycles: UInt64 = 0,
    pCycles: UInt64 = 0,
    qosDefault: UInt64 = 0,
    startTime: UInt64 = 1
) -> ResourceUsage.Counters {
    ResourceUsage.Counters(
        cpuTime: cpuTime,
        physicalFootprint: 0,
        lifetimeMaxFootprint: 0,
        bytesRead: 0,
        bytesWritten: 0,
        energy: energy,
        pEnergy: 0,
        cycles: cycles,
        pCycles: pCycles,
        instructions: 0,
        qosTime: ResourceUsage.QoSTime(
            userInteractive: 0,
            userInitiated: 0,
            defaultTier: qosDefault,
            legacy: 0,
            utility: 0,
            background: 0,
            maintenance: 0
        ),
        idleWakeups: 0,
        interruptWakeups: 0,
        startTime: startTime
    )
}

@Test func aReusedPidDoesNotInheritTheOldBaseline() {
    let dead = syntheticCounters(cpuTime: 1_000_000_000, energy: 500, startTime: 100)
    let reborn = syntheticCounters(cpuTime: 10_000_000_000, energy: 3_000, startTime: 200)

    // Same pid, different start time: the baseline belongs to a dead process,
    // and inheriting it would read the newcomer's lifetime as a burst — nine
    // phantom seconds of CPU here.
    let fresh = ProcessSampler.usage(pid: 42, counters: reborn, previous: dead, seconds: 1)
    #expect(fresh.cpu == 0)
    #expect(fresh.power == 0)

    let survivor = syntheticCounters(cpuTime: 2_000_000_000, energy: 900, startTime: 100)
    let continuing = ProcessSampler.usage(pid: 42, counters: survivor, previous: dead, seconds: 1)
    #expect(continuing.cpu == 1)
    #expect(abs(continuing.power - 400e-9) < 1e-12)
}

@Test func allZeroQoSReadsAsNoDataNotDefault() {
    // Lifetime buckets all zero: the process does not report QoS accounting,
    // and inventing "100 % default tier" from that would be a claim.
    let silent = syntheticCounters(cpuTime: 1_000_000_000, startTime: 7)
    #expect(ProcessSampler.usage(pid: 1, counters: silent, previous: nil, seconds: 1).qos == nil)

    // Nonzero lifetime buckets with a zero delta: honest idle, present and
    // all-zero rather than absent.
    let idle = syntheticCounters(cpuTime: 1_000_000_000, qosDefault: 500, startTime: 7)
    let usage = ProcessSampler.usage(pid: 1, counters: idle, previous: idle, seconds: 1)
    #expect(usage.qos == QoSBreakdown(
        userInteractive: 0,
        userInitiated: 0,
        defaultTier: 0,
        legacy: 0,
        utility: 0,
        background: 0,
        maintenance: 0
    ))
}

@Test func aShareOfNothingIsNotZeroPercent() {
    let still = syntheticCounters(startTime: 3)
    #expect(ProcessSampler.usage(pid: 1, counters: still, previous: still, seconds: 1).performanceCycleShare == nil)

    let before = syntheticCounters(cycles: 1_000, pCycles: 250, startTime: 3)
    let after = syntheticCounters(cycles: 2_000, pCycles: 1_000, startTime: 3)
    let usage = ProcessSampler.usage(pid: 1, counters: after, previous: before, seconds: 1)
    #expect(usage.performanceCycleShare == 0.75)
}
