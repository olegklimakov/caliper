import Darwin

/// What Caliper costs the machine it is measuring.
///
/// The footprint budget is a product requirement, so the app measures itself
/// with the same call it uses for every other process and can show the number
/// rather than claim it.
struct SelfMetricsSampler {
    private var previousCPUTime: UInt64?
    private var previousDiskBytes: UInt64?
    private var window = RateWindow()

    mutating func sample(at instant: ContinuousClock.Instant) -> SelfMetrics? {
        guard let counters = ResourceUsage.counters(for: getpid()) else { return nil }
        let disk = counters.bytesRead &+ counters.bytesWritten
        defer {
            previousCPUTime = counters.cpuTime
            previousDiskBytes = disk
        }

        // The window advances first: short-circuiting past it on the very first
        // call would cost an extra tick before any reading appears.
        let seconds = window.advance(to: instant)
        guard let previousCPUTime, let seconds else { return nil }

        return SelfMetrics(
            cpu: Double(counters.cpuTime.subtractingClamped(previousCPUTime)) / 1e9 / seconds,
            memoryFootprint: counters.physicalFootprint,
            diskRate: Double(disk.subtractingClamped(previousDiskBytes ?? disk)) / seconds
        )
    }

    mutating func resetBaseline() {
        previousCPUTime = nil
        previousDiskBytes = nil
        window.reset()
    }
}
