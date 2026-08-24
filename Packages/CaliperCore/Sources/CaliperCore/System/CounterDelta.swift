extension UInt64 {
    /// Difference between two readings of a monotonic counter.
    ///
    /// A smaller current value means the counter wrapped, the device was
    /// re-enumerated, or the machine slept through the interval. Zero is closer
    /// to the truth than the enormous delta the arithmetic would otherwise
    /// produce, and it keeps a spike out of every chart.
    func subtractingClamped(_ other: UInt64) -> UInt64 {
        self > other ? self - other : 0
    }
}

extension Duration {
    /// Elapsed seconds as a `Double`, for turning counter deltas into rates.
    var inSeconds: Double {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) * 1e-18
    }
}

/// The interval a rate is measured over.
///
/// Every counter-based sampler needs the same rule — the first reading only
/// establishes a baseline and produces nothing — and getting it subtly wrong
/// shows up as one bogus spike per launch, per wake, and per reconnected
/// device. It lives here once rather than in each sampler.
struct RateWindow {
    private var previous: ContinuousClock.Instant?

    /// Seconds since the previous call, or `nil` when there is no interval yet.
    mutating func advance(to instant: ContinuousClock.Instant) -> Double? {
        defer { previous = instant }
        guard let previous else { return nil }
        let seconds = (instant - previous).inSeconds
        return seconds > 0 ? seconds : nil
    }

    mutating func reset() {
        previous = nil
    }
}
