import Darwin
import Foundation
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
    // The kernel updates the lifetime maximum lazily, so the instantaneous
    // footprint can briefly exceed it — observed 32 KB apart on macOS 26 — and
    // ">= physicalFootprint" is not a fact. Half of it is.
    #expect(first.lifetimeMaxFootprint >= first.physicalFootprint / 2)
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

/// A live test because the birth rule is the sweep's, not a pure function's:
/// what makes a pid new is that its `ri_proc_start_abstime` is later than the
/// previous sweep began, and only a real pid has one.
@Test func aProcessBornSinceTheLastSweepIsCountedOnceAndNotAgain() throws {
    // A copy under a name nothing else on the machine answers to. The roster
    // is keyed by name, so a test that spawned `/bin/sleep` would be counting
    // every other `sleep` on the machine — including the ones this project's
    // own scripts run.
    let executable = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("caliper-birth-\(UUID().uuidString.prefix(8))")
    try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: executable)
    defer { try? FileManager.default.removeItem(at: executable) }

    var sampler = ProcessSampler()
    var clock = ContinuousClock.now
    // Two, because the rate window needs a pair before it reports anything.
    _ = sampler.sample(at: clock)
    clock = clock.advanced(by: .seconds(1))
    _ = sampler.sample(at: clock)

    let child = Process()
    child.executableURL = executable
    child.arguments = ["30"]
    try child.run()
    defer {
        child.terminate()
        child.waitUntilExit()
    }

    clock = clock.advanced(by: .seconds(1))
    guard let born = sampler.sample(at: clock) else {
        Issue.record("third sample should produce a reading")
        return
    }
    let name = executable.lastPathComponent
    #expect(born.births[name] == 1)

    // The same pid on the next sweep is not a new one — absent from `births`
    // rather than present with a zero, which is the half of the rule a table
    // of pids alone would get wrong after a wake or an unreadable moment.
    clock = clock.advanced(by: .seconds(1))
    guard let settled = sampler.sample(at: clock) else {
        Issue.record("fourth sample should produce a reading")
        return
    }
    #expect(settled.births[name] == nil)
}

/// The one assertion that can catch a pid counted twice. Births claim to be a
/// floor, so *more* of them than were actually spawned is always the bug — and
/// it only appears when a process is born while the sweep is reading the pid
/// list, because a spawn between two sweeps is counted correctly whichever
/// side of the read the watermark is taken. Spawning immediately before each
/// sweep is what opens that window; it is a guard on the invariant rather than
/// a reproduction of the race, and the upper bound is the half that matters.
@Test func birthsUnderChurnNeverExceedWhatWasSpawned() throws {
    let executable = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("caliper-churn-\(UUID().uuidString.prefix(8))")
    try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: executable)
    defer { try? FileManager.default.removeItem(at: executable) }
    let name = executable.lastPathComponent

    var children: [Process] = []
    defer {
        for child in children {
            child.terminate()
            child.waitUntilExit()
        }
    }

    var sampler = ProcessSampler()
    var clock = ContinuousClock.now
    _ = sampler.sample(at: clock)
    clock = clock.advanced(by: .seconds(1))
    _ = sampler.sample(at: clock)

    let spawned = 24
    var counted = 0
    func sweep() {
        clock = clock.advanced(by: .seconds(1))
        counted += sampler.sample(at: clock)?.births[name] ?? 0
    }
    for _ in 0..<spawned {
        let child = Process()
        child.executableURL = executable
        child.arguments = ["30"]
        try child.run()
        children.append(child)
        sweep()
    }
    // Three more, for any that were not yet in a pid list when their own sweep
    // read one.
    for _ in 0..<3 { sweep() }

    #expect(counted <= spawned)
    // And it has to be finding them, or the bound above holds vacuously.
    #expect(counted > 0)
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
