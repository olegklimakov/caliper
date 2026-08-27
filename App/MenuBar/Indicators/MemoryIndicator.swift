import AppKit
import CaliperCore

/// A column showing how much of memory is in use, with the percentage beside it.
///
/// Upright on purpose: a horizontal capsule filled from the left is what every
/// battery gauge on this platform looks like, including the real one a few icons
/// along in the same menu bar.
///
/// The column's *height* is the used fraction and its *colour* is the kernel's
/// pressure level — two different questions. A Mac sits near 90 % used and is
/// perfectly happy, so the colour is the part that says whether to care.
@MainActor
struct MemoryIndicator: MenuBarIndicator {
    let module = MenuBarModule.memory
    let layout: IndicatorLayout

    private let columnHeight: CGFloat = 12

    init(parts: ModuleParts) {
        layout = IndicatorLayout(parts: parts, graphWidth: 5, valueWidth: 26, gap: 7)
    }

    func identity(_ state: LiveMetrics) -> AnyHashable? {
        guard let memory = state.snapshot?.memory else { return nil }
        // Neither is worth a redraw when the half it belongs to is not
        // drawn.
        var identity: [Int] = []
        if layout.showsValue || layout.showsGraph {
            identity.append(Int((memory.usedFraction * 100).rounded()))
        }
        if layout.showsGraphic {
            identity.append(memory.pressure?.hashValue ?? -1)
        }
        return identity
    }

    func accessibilityLabel(_ state: LiveMetrics) -> String {
        guard let memory = state.snapshot?.memory else { return "Memory" }
        let pressure = memory.pressure.map { ", pressure \($0.rawValue)" } ?? ""
        return "Memory \(Int((memory.usedFraction * 100).rounded())) percent used\(pressure)"
    }

    func draw(_ state: LiveMetrics, in bounds: CGRect, style: IndicatorStyle) {
        guard let memory = state.snapshot?.memory else { return }

        let fraction = memory.usedFraction
        if let graph = layout.graph(in: bounds) {
            let column = CGRect(
                x: graph.minX,
                y: graph.midY - columnHeight / 2,
                width: graph.width,
                height: columnHeight
            )

            // A small radius, not a capsule: a stadium reads as a pill again.
            let track = NSBezierPath(roundedRect: column, xRadius: 2, yRadius: 2)
            style.secondary(Palette.track).setFill()
            track.fill()

            // From the bottom up, the way anything filling does.
            let filled = CGRect(
                x: column.minX,
                y: column.minY,
                width: column.width,
                height: max(2, column.height * fraction)
            )
            NSGraphicsContext.saveGraphicsState()
            track.addClip()
            style.accent(colour(for: memory.pressure)).setFill()
            filled.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        if let value = layout.value(in: bounds) {
            "\(Int((fraction * 100).rounded()))%".drawRightAligned(
                in: value,
                font: MenuBarMetrics.valueFont,
                colour: style.accent(.labelColor)
            )
        }
    }

    /// The symbol carries the pressure the column would have been coloured
    /// with: it is the half of this module that says whether to care.
    func iconColour(_ state: LiveMetrics) -> NSColor {
        colour(for: state.snapshot?.memory?.pressure)
    }

    /// Red only for critical, per the single-purpose severity palette.
    private func colour(for pressure: MemoryPressure?) -> NSColor {
        switch pressure {
        case .warning: Palette.warning
        case .critical: Palette.critical
        default: Palette.memory
        }
    }
}
