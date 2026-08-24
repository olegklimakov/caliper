import CaliperCore
import SwiftUI

struct SensorsPanel: View {
    let metrics: LiveMetrics
    let openHistory: () -> Void
    /// Non-nil when this panel is a room of the combined window.
    var onBack: (() -> Void)?

    private var sensors: SensorsSample? { metrics.snapshot?.sensors }

    var body: some View {
        PanelContainer {
            PanelHeader(
                onBack: onBack,
                title: "Sensors",
                value: metrics.currentPeakTemperature.map { TemperatureFormatter.string($0) } ?? "—",
                unit: "peak",
                chips: fanChip
            )

            ChartCard {
                LiveChart(
                    series: [
                        .init(
                            id: "temperature",
                            values: Array(metrics.peakTemperature),
                            colour: Color(Palette.temperature)
                        )
                    ],
                    range: temperatureRange,
                    filled: true
                )
            }

            if let groups = temperatureGroups, !groups.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Temperatures")
                    ForEach(groups, id: \.name) { group in
                        MetricRow(
                            name: group.name,
                            value: TemperatureFormatter.string(group.celsius),
                            fraction: fraction(of: group.celsius),
                            colour: Color(colour(for: group.celsius))
                        )
                    }
                }
            }

            if let fans = sensors?.fans, !fans.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Fans")
                    ForEach(fans, id: \.index) { fan in
                        MetricRow(
                            name: fanName(fan, count: fans.count),
                            value: fan.rpm > 0 ? "\(Int(fan.rpm)) RPM" : "Off",
                            fraction: fanFraction(fan),
                            colour: Color(Palette.cpuEfficiency)
                        )
                    }
                }
            }

            Divider()
            PanelFooter(detail: sensorCount, openHistory: openHistory)
        }
    }

    /// One row per group rather than per sensor: this machine reports fourteen
    /// die sensors with nothing to tell them apart, and fourteen near-identical
    /// rows would be a wall of noise. The hottest of each group is what matters.
    private var temperatureGroups: [(name: String, celsius: Double)]? {
        guard let sensors, !sensors.temperatures.isEmpty else { return nil }

        let grouped = Dictionary(grouping: sensors.realTemperatures) { $0.group }
        return SensorGroup.allCases.compactMap { group in
            guard let hottest = grouped[group]?.map(\.celsius).max() else { return nil }
            return (group.label, hottest)
        }
    }

    private var fanChip: [PanelChip.Model] {
        guard let fans = sensors?.fans, !fans.isEmpty else { return [] }
        let spinning = fans.contains { $0.rpm > 0 }
        return [
            PanelChip.Model(
                colour: Color(spinning ? Palette.cpuEfficiency : Palette.ok),
                label: "Fans",
                value: spinning ? "Active" : "Idle"
            )
        ]
    }

    /// A window wide enough to show change without making room noise look like
    /// a thermal event.
    private var temperatureRange: ClosedRange<Double>? {
        let values = Array(metrics.peakTemperature)
        guard let low = values.min(), let high = values.max() else { return 20...100 }
        return (low - 5)...(max(high + 5, low + 15))
    }

    private func fraction(of celsius: Double) -> Double {
        min(1, max(0, (celsius - 20) / 80))
    }

    private func colour(for celsius: Double) -> NSColor {
        switch celsius {
        case 100...: Palette.critical
        case 85...: Palette.warning
        default: Palette.ok
        }
    }

    private func fanName(_ fan: FanReading, count: Int) -> String {
        count == 1 ? "Fan" : "Fan \(fan.index + 1)"
    }

    private func fanFraction(_ fan: FanReading) -> Double? {
        guard let minimum = fan.minimumRPM, let maximum = fan.maximumRPM, maximum > minimum else {
            return nil
        }
        return max(0, (fan.rpm - minimum) / (maximum - minimum))
    }

    private var sensorCount: String {
        guard let count = sensors?.temperatures.count else { return "" }
        return "\(count) sensors tracked"
    }
}

extension SensorGroup {
    var label: String {
        switch self {
        case .cpuPerformance: "CPU P-cluster"
        case .cpuEfficiency: "CPU E-cluster"
        case .gpu: "GPU"
        case .socDie: "SoC die"
        case .drive: "SSD"
        case .battery: "Battery"
        case .calibration: "Calibration"
        case .other: "Other"
        }
    }
}
