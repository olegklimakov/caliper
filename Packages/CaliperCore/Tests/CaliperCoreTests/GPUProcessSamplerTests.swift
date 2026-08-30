import Darwin
import Foundation
import Testing

@testable import CaliperCore

// MARK: - Parsing, without IOKit

@Test func creatorStringYieldsThePidAndNothingElse() {
    #expect(GPUProcessSampler.pid(fromCreator: "pid 537, AccessibilityVis") == 537)
    // The name half is free text and may itself contain commas or digits.
    #expect(GPUProcessSampler.pid(fromCreator: "pid 12, App, With, Commas 9") == 12)
    #expect(GPUProcessSampler.pid(fromCreator: "537, NoPrefix") == nil)
    #expect(GPUProcessSampler.pid(fromCreator: "pid , Nameless") == nil)
    #expect(GPUProcessSampler.pid(fromCreator: "") == nil)
    #expect(GPUProcessSampler.pid(fromCreator: "pid 99999999999999, Overflow") == nil)
}

@Test func aClientSumsItsCommandQueues() {
    let queues: [[String: Any]] = [
        ["accumulatedGPUTime": 100],
        ["accumulatedGPUTime": 250],
        ["somethingElse": 7],
        ["accumulatedGPUTime": "not a number"],
    ]
    #expect(GPUProcessSampler.accumulatedTime(in: queues) == 350)
    #expect(GPUProcessSampler.accumulatedTime(in: []) == 0)
}

// MARK: - Accumulation rules, without IOKit

private func observation(_ entryID: UInt64, pid: pid_t, time: UInt64) -> GPUTimeAccumulator.Observation {
    GPUTimeAccumulator.Observation(entryID: entryID, pid: pid, time: time)
}

private func sameIdentity(_ pid: pid_t) -> UInt64? { 1 }
private func alwaysAlive(_ pid: pid_t) -> Bool { true }

@Test func clientsOfOnePidAllSum() {
    var accumulator = GPUTimeAccumulator()
    let totals = accumulator.fold(
        [observation(1, pid: 42, time: 100), observation(2, pid: 42, time: 30)],
        identity: sameIdentity,
        isAlive: alwaysAlive
    )
    #expect(totals[42] == 130)
}

@Test func aVanishedClientIsAnEndNotADecrease() {
    var accumulator = GPUTimeAccumulator()
    _ = accumulator.fold([observation(1, pid: 42, time: 100)], identity: sameIdentity, isAlive: alwaysAlive)

    // The client is gone; its time is kept, not subtracted.
    let after = accumulator.fold([], identity: sameIdentity, isAlive: alwaysAlive)
    #expect(after[42] == 100)

    // A new client starts its own count on top of what was retired.
    let rebuilt = accumulator.fold(
        [observation(9, pid: 42, time: 50)],
        identity: sameIdentity,
        isAlive: alwaysAlive
    )
    #expect(rebuilt[42] == 150)
}

@Test func aShrinkingClientHoldsItsHighWaterMark() {
    var accumulator = GPUTimeAccumulator()
    _ = accumulator.fold([observation(1, pid: 42, time: 100)], identity: sameIdentity, isAlive: alwaysAlive)

    // A destroyed command queue drops out of AppUsage, so a living client's
    // sum can fall; the total must not.
    let shrunk = accumulator.fold(
        [observation(1, pid: 42, time: 60)],
        identity: sameIdentity,
        isAlive: alwaysAlive
    )
    #expect(shrunk[42] == 100)

    let grown = accumulator.fold(
        [observation(1, pid: 42, time: 130)],
        identity: sameIdentity,
        isAlive: alwaysAlive
    )
    #expect(grown[42] == 130)
}

@Test func aReusedPidDoesNotInheritGPUTime() {
    var accumulator = GPUTimeAccumulator()
    _ = accumulator.fold([observation(1, pid: 42, time: 500)], identity: { _ in 100 }, isAlive: alwaysAlive)

    // Same pid, different start time: a new process, whose count starts at
    // its own clients alone.
    let reborn = accumulator.fold(
        [observation(7, pid: 42, time: 20)],
        identity: { _ in 200 },
        isAlive: alwaysAlive
    )
    #expect(reborn[42] == 20)
}

@Test func anUnreadablePidStillAccumulates() {
    var accumulator = GPUTimeAccumulator()
    // WindowServer: the kernel refuses its start time, so identity degrades
    // to the pid alone and accumulation continues.
    let unreadable: (pid_t) -> UInt64? = { _ in nil }
    _ = accumulator.fold([observation(1, pid: 88, time: 40)], identity: unreadable, isAlive: alwaysAlive)
    let after = accumulator.fold([observation(1, pid: 88, time: 90)], identity: unreadable, isAlive: alwaysAlive)
    #expect(after[88] == 90)
}

@Test func aDeadPidsRetainedTotalIsDropped() {
    var accumulator = GPUTimeAccumulator()
    _ = accumulator.fold([observation(1, pid: 42, time: 100)], identity: sameIdentity, isAlive: alwaysAlive)

    // The client is gone and so is the process: keeping the total would hand
    // it to whoever inherits the pid.
    let after = accumulator.fold([], identity: sameIdentity, isAlive: { _ in false })
    #expect(after[42] == nil)

    let next = accumulator.fold([], identity: sameIdentity, isAlive: alwaysAlive)
    #expect(next.isEmpty)
}

// MARK: - Live hardware and degradation

/// Serialized because the degradation case flips a process-wide environment
/// variable.
@Suite(.serialized) struct GPUAvailability {
    @Test func gpuSweepFindsRealWorkAndNeverCountsBackwards() {
        var sampler = GPUProcessSampler()
        // A Mac whose accelerator does not expose usage hides the feature;
        // that is a pass.
        guard sampler.isAvailable else { return }

        guard let first = sampler.sample() else {
            Issue.record("an available sampler should produce a sweep")
            return
        }
        #expect(!first.processes.isEmpty)
        #expect(first.processes == first.processes.sorted { $0.gpuTime > $1.gpuTime })
        #expect(first.processes.allSatisfy { !$0.name.isEmpty && $0.gpuTime > 0 })

        guard let second = sampler.sample() else {
            Issue.record("the second sweep should not fail")
            return
        }
        // The exit invariant: cumulative time never goes down.
        let before = Dictionary(uniqueKeysWithValues: first.processes.map { ($0.pid, $0.gpuTime) })
        for process in second.processes {
            if let earlier = before[process.pid] {
                #expect(process.gpuTime >= earlier, "pid \(process.pid) went backwards")
            }
        }
    }

    @Test func repeatedGPUSweepsDoNotLeak() {
        var sampler = GPUProcessSampler()
        guard sampler.isAvailable else { return }

        _ = sampler.sample()

        // Every sweep copies a CF array of dictionaries per client; an
        // unbalanced retain would strand tens of thousands of objects here.
        // The pool per iteration is what the dispatch queue provides in
        // production; without it the bridged collections pile up until the
        // test ends and 200 sweeps read as a 3.5 MB "leak" that is not one.
        let growth = footprintGrowth(under: 2_000_000) {
            for _ in 0..<200 {
                autoreleasepool {
                    _ = sampler.sample()
                }
            }
        }
        #expect(growth < 2_000_000, "footprint grew by \(growth) bytes")
    }

    @Test func hidesGPUWhenTheSweepIsRefused() async {
        setenv(GPUPolicy.environmentKey, "1", 1)
        defer { unsetenv(GPUPolicy.environmentKey) }

        var sampler = GPUProcessSampler()
        #expect(!GPUPolicy.allowsAcceleratorSweep)
        #expect(!sampler.isAvailable)
        #expect(sampler.sample() == nil)

        let coordinator = SamplingCoordinator(demand: .everything)
        await coordinator.tick()
        await coordinator.tick()
        let snapshot = await coordinator.latestSnapshot()
        #expect(snapshot.gpu == nil)
        // Everything else keeps working; the feature hides alone.
        #expect(snapshot.cpu != nil)
        #expect(snapshot.memory != nil)
    }
}
