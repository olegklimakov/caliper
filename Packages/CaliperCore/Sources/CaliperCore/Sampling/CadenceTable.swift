/// A group of readings taken together from one source.
public enum MetricKind: String, Sendable, CaseIterable, Codable {
    case cpu
    case memory
    case network
    /// Bytes read and written per second, from the block storage drivers.
    case diskActivity
    /// Mounted volumes and their free space — expensive and nearly static.
    case volumes
    /// Local addresses and Wi-Fi signal, which change when you join a network.
    case connection
    /// Temperatures and fans.
    case sensors
    /// Drive wear and SMART counters.
    case driveHealth
    case processes
    /// GPU time per process, from the accelerator's user clients.
    case gpu
    /// What the accelerator itself is doing — utilisation and memory, from its
    /// own statistics rather than from its clients.
    case gpuDevice
    /// Battery, adapter and low-power mode.
    case power
    case selfMetrics
}

/// How many base ticks pass between samples of each metric.
///
/// The coordinator runs a single one-second timer; everything slower is a
/// divisor of that tick rather than a timer of its own, so the app wakes the
/// CPU once a second at most.
///
/// Three rates per metric, picked by `MetricDemand`. *Foreground* is what a
/// metric costs while something on screen is drawing it. *Background* is what
/// it costs while it is merely being recorded — slow enough not to matter,
/// often enough that the history has something to fold. *Hidden* is what it
/// costs with the display asleep.
public enum CadenceTable {
    public static func interval(for kind: MetricKind, demand: MetricDemand) -> Int {
        let rates = rates(for: kind)
        guard demand.isVisible else { return rates.hidden }
        return demand.metrics.contains(kind) ? rates.foreground : rates.background
    }

    public static func isDue(_ kind: MetricKind, tick: UInt64, demand: MetricDemand) -> Bool {
        tick % UInt64(interval(for: kind, demand: demand)) == 0
    }

    /// All three rates for one metric, on one line, next to the reason they are
    /// what they are.
    ///
    /// One switch rather than three, so that a metric's whole story is read and
    /// edited in one place — and so a rate cannot be changed in one column and
    /// forgotten in the others.
    private static func rates(for kind: MetricKind) -> (foreground: Int, background: Int, hidden: Int) {
        switch kind {
        // The cheapest five, all under 0.15 ms a sweep, and the ones the
        // ten-second history buckets fold min/avg/max out of. Slowing them off
        // screen would cost the history its shape and save nothing worth
        // measuring, so background matches foreground. The accelerator's own
        // statistics measure 0.038 ms and belong here; its *clients* cost
        // thirty times that and do not.
        case .cpu, .memory, .network, .diskActivity, .gpuDevice: (1, 1, 5)
        case .volumes, .connection: (10, 30, 60)
        // A full pid sweep, one syscall per process.
        case .processes: (3, 10, 30)
        // Measured on an M5 Pro: 1.14 ms a sweep, cheaper than the pid sweep.
        // Nothing draws GPU until a surface asks for it, and nothing folds it
        // into history, so off screen it runs at drive-health rarity — the
        // closest this table comes to "never".
        case .gpu: (3, 600, 600)
        // Measured on an M5 Pro: a full sweep costs 29 ms, and 25 of those are
        // the fourteen SoC die sensors at 1.8 ms each — the most expensive read
        // in the app by an order of magnitude, and worth two seconds only where
        // the number is being watched move. A die climbs about 0.4 °C a second
        // under full load, so thirty seconds loses nothing the menu bar's badge
        // can show.
        case .sensors: (2, 30, 60)
        // Wear is measured in whole percent of a drive's lifetime; ten minutes
        // is already far more often than it can change, on screen or off.
        case .driveHealth: (600, 600, 600)
        // Set by how fast the number can change, not by what it costs: at
        // 0.121 ms it would sit in the group above, but a charge moves about a
        // point every five minutes and reading it every second is three
        // hundred reads for one change. Sixty seconds hidden is coarser than
        // the ten-second bucket, so the finest tier keeps one reading in six
        // there — which still answers "how fast did it drain overnight" at the
        // resolution anyone asks it.
        case .power: (5, 10, 60)
        case .selfMetrics: (10, 30, 30)
        }
    }
}
