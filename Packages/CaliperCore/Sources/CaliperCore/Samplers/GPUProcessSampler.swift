import Darwin
import Foundation
import IOKit

/// Cumulative GPU time per process, from each accelerator's user clients.
///
/// The clients are `!registered` and `!matched`, so matching them by class
/// finds zero — the recursive walk down from the accelerator is the only way
/// in. Public IOKit, but the properties are undocumented: the first Mac whose
/// accelerator names them differently loses this feature, not the app.
struct GPUProcessSampler {
    /// Probed once by doing the read; the coordinator checks this before
    /// scheduling a sweep.
    let isAvailable: Bool
    private var accumulator = GPUTimeAccumulator()

    init() {
        guard GPUPolicy.allowsAcceleratorSweep else {
            isAvailable = false
            return
        }
        isAvailable = !(Self.readClients() ?? []).isEmpty
    }

    mutating func sample() -> GPUSample? {
        guard isAvailable else { return nil }
        guard let sweep = Self.readClients() else { return nil }

        let totals = accumulator.fold(
            sweep,
            identity: { ResourceUsage.counters(for: $0)?.startTime },
            isAlive: { kill($0, 0) == 0 || errno == EPERM }
        )

        let processes = totals
            .filter { $0.value > 0 }
            .map { pid, nanoseconds in
                GPUProcessSample(
                    pid: pid,
                    name: ResourceUsage.name(for: pid),
                    gpuTime: Double(nanoseconds) / 1e9
                )
            }
            .sorted { $0.gpuTime != $1.gpuTime ? $0.gpuTime > $1.gpuTime : $0.pid < $1.pid }

        return GPUSample(sampledAt: Date(), processes: processes)
    }

    /// `IOUserClientCreator` reads `"pid 537, AccessibilityVis"`, and the name
    /// half is truncated at sixteen characters — the pid is the identity, and
    /// the display name comes from `ResourceUsage.name(for:)` instead.
    static func pid(fromCreator creator: String) -> pid_t? {
        guard creator.hasPrefix("pid ") else { return nil }
        let digits = creator.dropFirst(4).prefix(while: \.isNumber)
        guard !digits.isEmpty else { return nil }
        return pid_t(digits)
    }

    /// Sum of `accumulatedGPUTime` (nanoseconds) over a client's command
    /// queues; one client holds several, and they all count.
    static func accumulatedTime(in appUsage: [[String: Any]]) -> UInt64 {
        appUsage.reduce(0) { sum, queue in
            sum &+ ((queue["accumulatedGPUTime"] as? NSNumber)?.uint64Value ?? 0)
        }
    }

    /// One observation per user client, or nil when a walk was invalidated by
    /// registry churn — acting on a truncated walk would retire every client
    /// it never reached, and each would come back next sweep as "new" with its
    /// full total counted twice.
    private static func readClients() -> [GPUTimeAccumulator.Observation]? {
        var observations: [UInt64: GPUTimeAccumulator.Observation] = [:]
        var complete = true

        IORegistry.forEachService(matching: "IOAccelerator") { accelerator in
            let walked = IORegistry.forEachChild(of: accelerator) { child in
                guard let className = IORegistry.className(child),
                    className.hasSuffix("UserClient"),
                    let id = IORegistry.entryID(child),
                    let creator = IORegistry.string(child, "IOUserClientCreator"),
                    let pid = Self.pid(fromCreator: creator),
                    let appUsage = IORegistry.dictionaries(child, "AppUsage")
                else { return }
                observations[id] = GPUTimeAccumulator.Observation(
                    entryID: id,
                    pid: pid,
                    time: Self.accumulatedTime(in: appUsage)
                )
            }
            if !walked { complete = false }
        }

        return complete ? Array(observations.values) : nil
    }
}

/// The (pid, entry id) bookkeeping, free of IOKit so the churn rules are
/// testable with literal values.
///
/// The invariant the whole design serves: a process's total never goes down.
/// Activity Monitor's "GPU Time" is the reference, and a number that dips is
/// wrong twice — once now, and once more when the dip is averaged away.
struct GPUTimeAccumulator {
    struct Observation: Equatable {
        let entryID: UInt64
        let pid: pid_t
        /// Summed queue nanoseconds as of this sweep.
        let time: UInt64
    }

    private struct Client {
        let pid: pid_t
        /// High-water mark, not the last reading: each queue's counter is
        /// cumulative since the *queue* was created, and a destroyed queue
        /// drops out of `AppUsage` — so a living client's sum can fall. The
        /// clamp trades a bounded undercount on queue churn for a total that
        /// provably never decreases.
        var maxTime: UInt64
    }

    private struct Total {
        /// `ri_proc_start_abstime`, or nil when the kernel refuses the pid —
        /// WindowServer, the biggest GPU consumer, is another user's process.
        /// For those, identity degrades to the pid alone: dropping them every
        /// sweep would cost more than the unlikely undetected reuse.
        let startTime: UInt64?
        var retired: UInt64
    }

    private var clients: [UInt64: Client] = [:]
    private var totals: [pid_t: Total] = [:]

    /// Folds one sweep and returns cumulative nanoseconds per pid.
    mutating func fold(
        _ sweep: [Observation],
        identity: (pid_t) -> UInt64?,
        isAlive: (pid_t) -> Bool
    ) -> [pid_t: UInt64] {
        // A changed start time means the pid was reused; the predecessor's
        // state has to go before the retirement pass folds it into the
        // newborn.
        for pid in Set(sweep.map(\.pid)) {
            let start = identity(pid)
            if let known = totals[pid] {
                if known.startTime != start {
                    totals[pid] = Total(startTime: start, retired: 0)
                    clients = clients.filter { $0.value.pid != pid }
                }
            } else {
                totals[pid] = Total(startTime: start, retired: 0)
            }
        }

        // A client absent from the sweep has ended; its last value is kept,
        // not subtracted. Registry entry ids are never reused within a boot,
        // so a returning client is a new entry, never a resurrection.
        let seen = Set(sweep.map(\.entryID))
        for (id, client) in clients where !seen.contains(id) {
            totals[client.pid]?.retired &+= client.maxTime
            clients.removeValue(forKey: id)
        }

        for observation in sweep {
            let previous = clients[observation.entryID]?.maxTime ?? 0
            clients[observation.entryID] = Client(
                pid: observation.pid,
                maxTime: max(previous, observation.time)
            )
        }

        // A pid with no live client keeps its retired total only while it is
        // still the same process — an app that tears down its Metal context
        // and rebuilds one later keeps its lifetime figure, but a total held
        // for a dead pid would be handed to whoever inherits the number.
        var liveTime: [pid_t: UInt64] = [:]
        for client in clients.values {
            liveTime[client.pid, default: 0] &+= client.maxTime
        }
        totals = totals.filter { pid, total in
            liveTime[pid] != nil || (isAlive(pid) && identity(pid) == total.startTime)
        }

        var cumulative: [pid_t: UInt64] = [:]
        cumulative.reserveCapacity(totals.count)
        for (pid, total) in totals {
            cumulative[pid] = total.retired &+ (liveTime[pid] ?? 0)
        }
        return cumulative
    }
}
