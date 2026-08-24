import CaliperCore

/// What a module reads right now, in the shape the combined window shows it: a
/// headline value and the detail that qualifies it.
///
/// Apart from the view because five modules' worth of "which formatter, of
/// which field" is not layout, and a row that has to answer it inline stops
/// being a row. Deliberately not shared with the dashboard's sidebar, which
/// wants one bare number in a narrow column and reads memory in gigabytes
/// rather than as a percentage — the same question asked of a different
/// surface, not the same answer.
@MainActor
struct ModuleReading {
    /// The number itself. An em dash when the metric has not reported yet —
    /// never a zero, which would read as a measurement.
    let value: String
    /// What the number is of: how much memory that percentage is, which sensor
    /// is the hottest, the rate in the other direction. Empty when the module
    /// has nothing to add.
    let note: String

    init(_ module: MenuBarModule, metrics: LiveMetrics) {
        let snapshot = metrics.snapshot
        switch module {
        case .cpu:
            value = snapshot?.cpu.map { PercentFormatter.string($0.total) } ?? "—"
            note = snapshot?.cpu.map { "\($0.cores.count) cores" } ?? ""
        case .memory:
            let memory = snapshot?.memory
            value = memory.map { PercentFormatter.string($0.usedFraction) } ?? "—"
            note = memory.map { ByteFormatter.memory($0.used) } ?? ""
        case .network:
            let network = snapshot?.network
            value = network.map { "\u{2193} \(RateFormatter.panel($0.downloadRate))" } ?? "—"
            // The short form for the second rate: the row has one column for
            // the number that matters and a corner for the one that qualifies
            // it, and "1 023 KB/s" does not fit in a corner.
            note = network.map { "\u{2191} \(RateFormatter.menuBar($0.uploadRate))" } ?? ""
        case .disk:
            let volume = snapshot?.volumes?.first
            value = volume.map { ByteFormatter.capacity($0.availableCapacity) } ?? "—"
            note = volume == nil ? "" : "free"
        case .temperature:
            value = metrics.currentPeakTemperature.map { TemperatureFormatter.string($0) } ?? "—"
            // The sensor's own name, so a peak that looks alarming can be read
            // as the drive or the battery rather than the chip.
            note = snapshot?.sensors?.realTemperatures.max { $0.celsius < $1.celsius }?.name ?? ""
        }
    }
}
