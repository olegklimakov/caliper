import AppKit
import CaliperCore

/// A sparkline of the last minute with the current percentage beside it.
///
/// The sparkline is the point of showing both: a single number tells you the
/// machine is at 40 %, the line tells you whether it is on the way up. Either
/// half can be switched off — the line is what someone watching a build wants
/// and pure waste to someone who only reads the number.
@MainActor
struct CPUIndicator: MenuBarIndicator {
    let module = MenuBarModule.cpu
    let layout: IndicatorLayout

    init(parts: ModuleParts) {
        layout = IndicatorLayout(parts: parts, graphWidth: 28, valueWidth: 26, gap: 2)
    }

    func identity(_ state: LiveMetrics) -> AnyHashable? {
        guard let total = state.snapshot?.cpu?.total else { return nil }
        // What will actually be drawn: the rounded percentage and the sparkline
        // at the resolution it is drawn at. Comparing the whole five-minute
        // buffer instead meant allocating and comparing three hundred values a
        // second to conclude that a quiet machine's line had not moved — and
        // with the sparkline switched off there is nothing to compare at all.
        var identity: [Int] = []
        if layout.showsValue {
            identity.append(percentage(total))
        }
        if layout.showsGraph {
            identity += Downsample.peaks(of: state.cpuTotal, to: Int(layout.graphWidth))
                .map(percentage)
        }
        return identity
    }

    func accessibilityLabel(_ state: LiveMetrics) -> String {
        guard let total = state.snapshot?.cpu?.total else { return "CPU" }
        // Read whether or not the number is drawn: a strip showing only a line
        // still has a percentage to report, and VoiceOver is the one reader
        // that cannot infer it from the shape.
        return "CPU \(percentage(total)) percent"
    }

    func draw(_ state: LiveMetrics, in bounds: CGRect, style: IndicatorStyle) {
        guard let total = state.snapshot?.cpu?.total else { return }

        if let graph = layout.graph(in: bounds) {
            Sparkline.stroke(
                values: state.cpuTotal,
                in: graph.insetBy(dx: 0, dy: 3),
                colour: style.accent(Palette.cpu),
                lineWidth: 1
            )
        }
        if let value = layout.value(in: bounds) {
            "\(percentage(total))%".drawRightAligned(
                in: value,
                font: MenuBarMetrics.valueFont,
                colour: style.accent(.labelColor)
            )
        }
    }

    private func percentage(_ fraction: Double) -> Int {
        Int((fraction * 100).rounded())
    }
}
