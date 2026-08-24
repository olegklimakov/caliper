import Darwin
import Foundation

/// The heaviest processes by CPU and by memory.
///
/// This is the most expensive sampler in the app — one syscall per process, on
/// a machine that routinely runs six hundred of them — so the pid buffer is
/// kept between ticks, names are resolved only for the handful that make the
/// lists, and the cadence table runs it in seconds rather than every tick.
struct ProcessSampler {
    private var pids: [pid_t] = []
    private var previousCPUTime: [pid_t: UInt64] = [:]
    private var previousDiskBytes: [pid_t: UInt64] = [:]
    private var window = RateWindow()

    /// How many processes each list keeps. Panels show a handful; asking for
    /// more would only cost more name lookups.
    private let limit = 10

    mutating func sample(at instant: ContinuousClock.Instant) -> ProcessesSample? {
        guard let count = readPIDs() else { return nil }

        var cpuTimes: [pid_t: UInt64] = [:]
        cpuTimes.reserveCapacity(count)
        var diskBytes: [pid_t: UInt64] = [:]
        diskBytes.reserveCapacity(count)
        var candidates: [(pid: pid_t, cpuTime: UInt64, footprint: UInt64, disk: UInt64)] = []
        candidates.reserveCapacity(count)

        for index in 0..<count {
            let pid = pids[index]
            // Processes come and go between the pid sweep and this call; a dead
            // one is simply not in the list any more.
            guard pid > 0, let counters = ResourceUsage.counters(for: pid) else { continue }
            let disk = counters.bytesRead &+ counters.bytesWritten
            cpuTimes[pid] = counters.cpuTime
            diskBytes[pid] = disk
            candidates.append((pid, counters.cpuTime, counters.physicalFootprint, disk))
        }

        defer {
            previousCPUTime = cpuTimes
            previousDiskBytes = diskBytes
        }
        guard let seconds = window.advance(to: instant) else { return nil }

        // A process that appeared during the interval has no baseline, so its
        // lifetime CPU time is not mistaken for a burst of activity.
        let usage = candidates.map { candidate -> Usage in
            let before = previousCPUTime[candidate.pid] ?? candidate.cpuTime
            let nanoseconds = candidate.cpuTime.subtractingClamped(before)
            let diskBefore = previousDiskBytes[candidate.pid] ?? candidate.disk
            return Usage(
                pid: candidate.pid,
                cpu: Double(nanoseconds) / 1e9 / seconds,
                footprint: candidate.footprint,
                diskRate: Double(candidate.disk.subtractingClamped(diskBefore)) / seconds
            )
        }

        let byCPU = usage.sorted { $0.cpu > $1.cpu }.prefix(limit)
        let byMemory = usage.sorted { $0.footprint > $1.footprint }.prefix(limit)
        // Only processes actually touching storage; a list of zeroes would say
        // nothing about which app is keeping the disk busy.
        let byDisk = usage.filter { $0.diskRate > 0 }
            .sorted { $0.diskRate > $1.diskRate }
            .prefix(limit)

        // Names cost a syscall each, so only the listed processes are resolved,
        // and a process on both lists only once.
        var names: [pid_t: String] = [:]
        for entry in byCPU + byMemory + byDisk where names[entry.pid] == nil {
            names[entry.pid] = ResourceUsage.name(for: entry.pid)
        }

        func samples(_ entries: some Sequence<Usage>) -> [ProcessSample] {
            entries.map { entry in
                ProcessSample(
                    pid: entry.pid,
                    name: names[entry.pid] ?? "pid \(entry.pid)",
                    cpu: entry.cpu,
                    memoryFootprint: entry.footprint,
                    diskRate: entry.diskRate
                )
            }
        }

        return ProcessesSample(
            sampledAt: Date(),
            topByCPU: samples(byCPU),
            topByMemory: samples(byMemory),
            topByDisk: samples(byDisk)
        )
    }

    private struct Usage {
        let pid: pid_t
        let cpu: Double
        let footprint: UInt64
        let diskRate: Double
    }

    mutating func resetBaseline() {
        previousCPUTime = [:]
        previousDiskBytes = [:]
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
