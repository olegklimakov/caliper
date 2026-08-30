import Darwin

/// What Caliper costs the machine it is measuring.
///
/// The footprint budget is a product requirement, so the app measures itself
/// with the same call it uses for every other process and can show the number
/// rather than claim it.
struct SelfMetricsSampler {
    private var previous: ResourceUsage.Counters?
    private var window = RateWindow()

    mutating func sample(at instant: ContinuousClock.Instant) -> SelfMetrics? {
        guard let counters = ResourceUsage.counters(for: getpid()) else { return nil }
        defer { previous = counters }

        // The window advances first: short-circuiting past it on the very first
        // call would cost an extra tick before any reading appears.
        let seconds = window.advance(to: instant)
        guard let previous, let seconds else { return nil }

        let disk = counters.bytesRead &+ counters.bytesWritten
        let diskBefore = previous.bytesRead &+ previous.bytesWritten
        return SelfMetrics(
            cpu: Double(counters.cpuTime.subtractingClamped(previous.cpuTime)) / 1e9 / seconds,
            memoryFootprint: counters.physicalFootprint,
            diskRate: Double(disk.subtractingClamped(diskBefore)) / seconds,
            power: Double(counters.energy.subtractingClamped(previous.energy)) / 1e9 / seconds
        )
    }

    mutating func resetBaseline() {
        previous = nil
        window.reset()
    }
}
