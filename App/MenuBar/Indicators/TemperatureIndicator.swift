import AppKit

/// The hottest real sensor, with a dot that only turns red when it matters.
@MainActor
struct TemperatureIndicator: MenuBarIndicator {
    let module = MenuBarModule.temperature
    let layout: IndicatorLayout

    init(parts: ModuleParts) {
        layout = IndicatorLayout(parts: parts, graphWidth: 6, valueWidth: 30, gap: 4)
    }

    /// How hot is worth saying so about.
    ///
    /// Apple Silicon runs warm by design: these mark "working hard" and
    /// "throttling territory", not "broken". One ladder rather than a threshold
    /// pair read in three places — the dot's colour, what VoiceOver says and
    /// what counts as a change worth redrawing are all the same judgement.
    private enum Severity: Int {
        case normal, warm, critical

        init(_ celsius: Double) {
            self =
                switch celsius {
                case 100...: .critical
                case 85...: .warm
                default: .normal
                }
        }

        var colour: NSColor {
            switch self {
            case .critical: Palette.critical
            case .warm: Palette.warning
            case .normal: Palette.ok
            }
        }

        /// A colour is not something VoiceOver can read.
        var spoken: String {
            switch self {
            case .critical: ", critical"
            case .warm: ", warm"
            case .normal: ""
            }
        }
    }

    func identity(_ state: LiveMetrics) -> AnyHashable? {
        guard let peak = state.currentPeakTemperature else { return nil }
        // The dot has three states and the number has a degree. Keyed on the
        // degree with the number switched off, the item would be handed a new
        // image every time the machine warmed by one, for a picture that had
        // not changed.
        return layout.showsValue ? Int(peak.rounded()) : Severity(peak).rawValue
    }

    /// The symbol carries the severity the dot would have shown.
    func iconColour(_ state: LiveMetrics) -> NSColor {
        state.currentPeakTemperature.map { Severity($0).colour } ?? Palette.ok
    }

    func accessibilityLabel(_ state: LiveMetrics) -> String {
        guard let peak = state.currentPeakTemperature else { return "Sensors" }
        return "Hottest sensor \(Int(peak.rounded())) degrees\(Severity(peak).spoken)"
    }

    func draw(_ state: LiveMetrics, in bounds: CGRect, style: IndicatorStyle) {
        guard let peak = state.currentPeakTemperature else { return }

        if let graph = layout.graph(in: bounds) {
            let dot = CGRect(x: graph.minX, y: graph.midY - 3, width: graph.width, height: 6)
            style.accent(Severity(peak).colour).setFill()
            NSBezierPath(ovalIn: dot).fill()
        }
        if let value = layout.value(in: bounds) {
            TemperatureFormatter.string(peak).drawRightAligned(
                in: value,
                font: MenuBarMetrics.valueFont,
                colour: style.accent(.labelColor)
            )
        }
    }
}
