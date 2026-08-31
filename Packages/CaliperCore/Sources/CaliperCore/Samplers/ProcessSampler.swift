import Darwin
import Foundation

/// The heaviest processes by CPU, memory, disk and power.
///
/// This is the most expensive sampler in the app — one syscall per process, on
/// a machine that routinely runs six hundred of them — so the pid buffer is
/// kept between ticks, a pid is named once for as long as it lives, and the
/// cadence table runs the sweep in seconds rather than every tick.
struct ProcessSampler {
    private var pids = PIDBuffer()
    private var previous: [pid_t: ResourceUsage.Counters] = [:]
    private var identities: [pid_t: Identity] = [:]
    private var window = RateWindow()

    /// How many processes each list keeps. Panels show a handful, and the
    /// history's own depth is its business — what a bucket keeps is decided
    /// over the whole bucket, not over whichever sweep was last.
    private let limit = 10

    /// A pid's name and path, and the start time that says it is still the
    /// same process. Held between sweeps because neither can change while a
    /// pid lives: identifying every pid once per lifetime is cheaper than
    /// identifying the listed forty every second, which is what this replaced.
    /// A build that spawns hundreds of short-lived pids pays for each of them
    /// once.
    private struct Identity {
        let startTime: UInt64
        let name: String
        let path: String?
    }

    mutating func sample(at instant: ContinuousClock.Instant, watching: Set<String> = []) -> ProcessesSample? {
        guard let list = pids.read() else { return nil }

        var current: [pid_t: ResourceUsage.Counters] = [:]
        current.reserveCapacity(list.count)
        var unreadableCount = 0

        for pid in list {
            guard pid > 0 else {
                // pid 0 is kernel_task, refused like every root-owned pid.
                unreadableCount += 1
                continue
            }
            guard let counters = ResourceUsage.counters(for: pid) else {
                unreadableCount += 1
                continue
            }
            current[pid] = counters
        }

        defer { previous = current }
        guard let seconds = window.advance(to: instant) else { return nil }

        // Identity before rates: the watch list is stated by name, so a pid
        // has to be named before it can be told from the ones nobody asked
        // for. Rebuilding the table rather than pruning it retires exited and
        // reused pids in the same pass.
        var live: [pid_t: Identity] = [:]
        live.reserveCapacity(current.count)
        var roster: [String: ProcessIdentity] = [:]
        for (pid, counters) in current {
            let identity: Identity
            if let known = identities[pid], known.startTime == counters.startTime {
                identity = known
            } else {
                let read = ResourceUsage.identity(for: pid)
                identity = Identity(startTime: counters.startTime, name: read.name, path: read.path)
            }
            live[pid] = identity
            roster[identity.name] = ProcessIdentity(name: identity.name, path: identity.path)
        }
        identities = live

        let usage = current.map { pid, counters in
            Self.usage(pid: pid, counters: counters, previous: previous[pid], seconds: seconds)
        }

        let byCPU = usage.sorted { $0.cpu > $1.cpu }.prefix(limit)
        let byMemory = usage.sorted { $0.footprint > $1.footprint }.prefix(limit)
        // Only processes actually touching storage; a list of zeroes would say
        // nothing about which app is keeping the disk busy. Power follows the
        // same rule.
        let byDisk = usage.filter { $0.diskRate > 0 }
            .sorted { $0.diskRate > $1.diskRate }
            .prefix(limit)
        let byPower = usage.filter { $0.power > 0 }
            .sorted { $0.power > $1.power }
            .prefix(limit)

        let watched = watching.isEmpty
            ? []
            : usage.filter { watching.contains(live[$0.pid]?.name ?? "") }

        func samples(_ entries: some Sequence<Usage>) -> [ProcessSample] {
            entries.map { entry in
                ProcessSample(
                    pid: entry.pid,
                    name: live[entry.pid]?.name ?? "pid \(entry.pid)",
                    cpu: entry.cpu,
                    memoryFootprint: entry.footprint,
                    diskRate: entry.diskRate,
                    power: entry.power,
                    wakeupsPerSecond: entry.wakeupsPerSecond,
                    performanceCycleShare: entry.performanceCycleShare,
                    qos: entry.qos
                )
            }
        }

        return ProcessesSample(
            sampledAt: Date(),
            interval: seconds,
            topByCPU: samples(byCPU),
            topByMemory: samples(byMemory),
            topByDisk: samples(byDisk),
            topByPower: samples(byPower),
            watched: samples(watched),
            roster: Array(roster.values),
            unreadableCount: unreadableCount
        )
    }

    /// Internal, and static, so the reuse and QoS rules are testable without
    /// live pids.
    static func usage(
        pid: pid_t,
        counters: ResourceUsage.Counters,
        previous: ResourceUsage.Counters?,
        seconds: Double
    ) -> Usage {
        // A pid is only the same process if it started at the same instant.
        // macOS reuses pids; without this check a reborn pid inherits its
        // predecessor's baseline — clamped to zero when the new counters are
        // smaller, and read as a burst of activity when they are larger. A
        // process first seen this sweep seeds itself the same way, so its
        // lifetime totals are not mistaken for a burst either.
        let baseline: ResourceUsage.Counters
        if let previous, previous.startTime == counters.startTime {
            baseline = previous
        } else {
            baseline = counters
        }

        let cyclesDelta = counters.cycles.subtractingClamped(baseline.cycles)
        // The two cycle counters are read non-atomically by the kernel, so the
        // performance share is clamped to the total it is a share of.
        let pCyclesDelta = min(counters.pCycles.subtractingClamped(baseline.pCycles), cyclesDelta)
        let wakeups = counters.idleWakeups.subtractingClamped(baseline.idleWakeups)
            &+ counters.interruptWakeups.subtractingClamped(baseline.interruptWakeups)

        let qos: QoSBreakdown?
        if counters.qosTime.total == 0 {
            qos = nil
        } else {
            func coreShare(_ bucket: KeyPath<ResourceUsage.QoSTime, UInt64>) -> Double {
                let delta = counters.qosTime[keyPath: bucket]
                    .subtractingClamped(baseline.qosTime[keyPath: bucket])
                return Double(delta) / 1e9 / seconds
            }
            qos = QoSBreakdown(
                userInteractive: coreShare(\.userInteractive),
                userInitiated: coreShare(\.userInitiated),
                defaultTier: coreShare(\.defaultTier),
                legacy: coreShare(\.legacy),
                utility: coreShare(\.utility),
                background: coreShare(\.background),
                maintenance: coreShare(\.maintenance)
            )
        }

        return Usage(
            pid: pid,
            cpu: Double(counters.cpuTime.subtractingClamped(baseline.cpuTime)) / 1e9 / seconds,
            footprint: counters.physicalFootprint,
            readRate: Double(counters.bytesRead.subtractingClamped(baseline.bytesRead)) / seconds,
            writeRate: Double(counters.bytesWritten.subtractingClamped(baseline.bytesWritten)) / seconds,
            power: Double(counters.energy.subtractingClamped(baseline.energy)) / 1e9 / seconds,
            wakeupsPerSecond: Double(wakeups) / seconds,
            performanceCycleShare: cyclesDelta == 0 ? nil : Double(pCyclesDelta) / Double(cyclesDelta),
            cyclesDelta: cyclesDelta,
            pCyclesDelta: pCyclesDelta,
            qos: qos
        )
    }

    struct Usage {
        let pid: pid_t
        let cpu: Double
        let footprint: UInt64
        let readRate: Double
        let writeRate: Double
        let power: Double
        let wakeupsPerSecond: Double
        let performanceCycleShare: Double?
        /// Raw cycle deltas, kept so a family total can divide summed p-cycles
        /// by summed cycles rather than average the members' shares — cores
        /// retire cycles at different rates, and an average would weight them
        /// as equals.
        let cyclesDelta: UInt64
        let pCyclesDelta: UInt64
        let qos: QoSBreakdown?

        var diskRate: Double { readRate + writeRate }
    }

    /// Names survive: a pid's identity does not change across a sleep, and the
    /// start-time check catches the ones reused while the machine was out.
    mutating func resetBaseline() {
        previous = [:]
        window.reset()
    }
}
