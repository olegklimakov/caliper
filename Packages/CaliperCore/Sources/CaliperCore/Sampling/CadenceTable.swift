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
    case selfMetrics
}

/// How many base ticks pass between samples of each metric.
///
/// The coordinator runs a single one-second timer; everything slower is a
/// divisor of that tick rather than a timer of its own, so the app wakes the
/// CPU once a second at most.
public enum CadenceTable {
    public static func interval(for kind: MetricKind, at level: ActivityLevel) -> Int {
        switch kind {
        case .cpu, .memory, .network, .diskActivity:
            // Live values back the menu bar indicators, so they run at the base
            // rate whenever anything is on screen.
            level == .hidden ? 5 : 1
        case .volumes, .connection:
            switch level {
            case .hidden: 60
            case .menuBarOnly: 30
            case .panelOpen, .dashboardOpen: 10
            }
        case .processes:
            // The most expensive sampler: a full pid sweep with a syscall each.
            switch level {
            case .hidden: 30
            case .menuBarOnly: 10
            case .panelOpen, .dashboardOpen: 3
            }
        case .sensors:
            // Measured on an M5 Pro: a full sweep costs 29 ms, and 25 of those
            // are the fourteen SoC die sensors at 1.8 ms each. That is the most
            // expensive read in the app, and the half-hour footprint run showed
            // it was a third of a budget the whole app has to fit inside. All
            // the menu bar shows is a badge, and a die climbs about 0.4 °C a
            // second under full load, so thirty seconds loses nothing anyone
            // can see. With a panel open, where the number is being read, the
            // cost is worth paying.
            switch level {
            case .hidden: 60
            case .menuBarOnly: 30
            case .panelOpen, .dashboardOpen: 2
            }
        case .driveHealth:
            // Wear is measured in whole percent of a drive's lifetime; ten
            // minutes is already far more often than it can change.
            600
        case .selfMetrics:
            level == .hidden ? 30 : 10
        }
    }

    public static func isDue(_ kind: MetricKind, tick: UInt64, at level: ActivityLevel) -> Bool {
        tick % UInt64(interval(for: kind, at: level)) == 0
    }
}
