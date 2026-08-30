import Darwin
import Foundation

/// The heaviest processes by CPU, memory, disk and power.
///
/// This is the most expensive sampler in the app — one syscall per process, on
/// a machine that routinely runs six hundred of them — so the pid buffer is
/// kept between ticks, names are resolved only for the handful that make the
/// lists, and the cadence table runs it in seconds rather than every tick.
struct ProcessSampler {
    private var pids: [pid_t] = []
    private var previous: [pid_t: ResourceUsage.Counters] = [:]
    private var window = RateWindow()

    /// How many processes each list keeps. Panels show a handful; asking for
    /// more would only cost more name lookups.
    private let limit = 10

    mutating func sample(at instant: ContinuousClock.Instant) -> ProcessesSample? {
        guard let count = readPIDs() else { return nil }

        var current: [pid_t: ResourceUsage.Counters] = [:]
        current.reserveCapacity(count)
        var unreadableCount = 0

        for index in 0..<count {
            let pid = pids[index]
            guard pid > 0 else { continue }
            guard let counters = ResourceUsage.counters(for: pid) else {
                // Root-owned pids refuse the call — about a quarter of the
                // machine — and a process that exited between the pid sweep
                // and this read lands here too.
                unreadableCount += 1
                continue
            }
            current[pid] = counters
        }

        defer { previous = current }
        guard let seconds = window.advance(to: instant) else { return nil }

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

        // Names cost a syscall each, so only the listed processes are resolved,
        // and a process on several lists only once.
        var names: [pid_t: String] = [:]
        for entry in byCPU + byMemory + byDisk + byPower where names[entry.pid] == nil {
            names[entry.pid] = ResourceUsage.name(for: entry.pid)
        }

        func samples(_ entries: some Sequence<Usage>) -> [ProcessSample] {
            entries.map { entry in
                ProcessSample(
                    pid: entry.pid,
                    name: names[entry.pid] ?? "pid \(entry.pid)",
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
            topByCPU: samples(byCPU),
            topByMemory: samples(byMemory),
            topByDisk: samples(byDisk),
            topByPower: samples(byPower),
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

        let disk = counters.bytesRead &+ counters.bytesWritten
        let diskBefore = baseline.bytesRead &+ baseline.bytesWritten
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
            func share(_ bucket: KeyPath<ResourceUsage.QoSTime, UInt64>) -> Double {
                let delta = counters.qosTime[keyPath: bucket]
                    .subtractingClamped(baseline.qosTime[keyPath: bucket])
                return Double(delta) / 1e9 / seconds
            }
            qos = QoSBreakdown(
                userInteractive: share(\.userInteractive),
                userInitiated: share(\.userInitiated),
                defaultTier: share(\.defaultTier),
                legacy: share(\.legacy),
                utility: share(\.utility),
                background: share(\.background),
                maintenance: share(\.maintenance)
            )
        }

        return Usage(
            pid: pid,
            cpu: Double(counters.cpuTime.subtractingClamped(baseline.cpuTime)) / 1e9 / seconds,
            footprint: counters.physicalFootprint,
            diskRate: Double(disk.subtractingClamped(diskBefore)) / seconds,
            power: Double(counters.energy.subtractingClamped(baseline.energy)) / 1e9 / seconds,
            wakeupsPerSecond: Double(wakeups) / seconds,
            performanceCycleShare: cyclesDelta == 0 ? nil : Double(pCyclesDelta) / Double(cyclesDelta),
            qos: qos
        )
    }

    struct Usage {
        let pid: pid_t
        let cpu: Double
        let footprint: UInt64
        let diskRate: Double
        let power: Double
        let wakeupsPerSecond: Double
        let performanceCycleShare: Double?
        let qos: QoSBreakdown?
    }

    mutating func resetBaseline() {
        previous = [:]
        window.reset()
    }

    /// Fills the reused pid buffer and returns how many entries are valid.
    private mutating func readPIDs() -> Int? {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return nil }

        // Headroom so a process spawned between the two calls does not force a
        // reallocation on the next tick.
        if pids.count < Int(count) {
            pids = [pid_t](repeating: 0, count: Int(count) + 64)
        }

        let bytes = Int32(pids.count * MemoryLayout<pid_t>.size)
        let written = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listallpids(buffer.baseAddress, bytes)
        }
        guard written > 0 else { return nil }
        return Int(written)
    }
}
