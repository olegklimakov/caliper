import AppKit
import CaliperCore

/// Two opposing rates — down over up, read over write — as a mirrored
/// sparkline with both numbers beside it.
///
/// Network and disk ask the same question in the same shape, so they share one
/// renderer rather than two that drift apart.
@MainActor
struct DualRateIndicator: MenuBarIndicator {
    let module: MenuBarModule
    let layout: IndicatorLayout

    /// Rates for the current tick.
    let rates: (LiveMetrics) -> (primary: Double, secondary: Double)?
    /// History for the mirrored bars.
    let history: (LiveMetrics) -> (primary: RingBuffer<Double>, secondary: RingBuffer<Double>)
    let primaryColour: NSColor
    let secondaryColour: NSColor
    let primarySymbol: String
    let secondarySymbol: String
    /// Spoken rather than drawn: "down" reads better than "↓".
    let primaryName: String
    let secondaryName: String

    func identity(_ state: LiveMetrics) -> AnyHashable? {
        guard let rates = rates(state) else { return nil }
        guard layout.showsValue else {
            guard layout.showsGraph else { return 0 }
            // With the numbers gone the bars are the whole module, and they
            // scroll every tick. Keyed on the rates instead, an idle link —
            // where the formatted rate is the same string minute after minute —
            // would leave the one thing on screen frozen.
            let series = history(state)
            return bars(series.primary) + bars(series.secondary)
        }
        return [RateFormatter.menuBar(rates.primary), RateFormatter.menuBar(rates.secondary)]
    }

    /// The bars as drawn: one point of bar and one of gap, which is the
    /// resolution `Sparkline.fillBars` reduces the series to.
    private func bars(_ series: RingBuffer<Double>) -> [Int] {
        Downsample.peaks(of: series, to: Int(layout.graphWidth / 2)).map { Int($0) }
    }

    func accessibilityLabel(_ state: LiveMetrics) -> String {
        guard let rates = rates(state) else { return module.title }
        return "\(module.title), \(primaryName) \(RateFormatter.panel(rates.primary)), "
            + "\(secondaryName) \(RateFormatter.panel(rates.secondary))"
    }

    func draw(_ state: LiveMetrics, in bounds: CGRect, style: IndicatorStyle) {
        guard let rates = rates(state) else { return }

        if let graph = layout.graph(in: bounds) {
            let series = history(state)
            // A shared scale, so the two halves stay comparable, with a floor
            // that keeps idle noise flat instead of amplifying it to full
            // height.
            let scale = max(series.primary.max() ?? 0, series.secondary.max() ?? 0, 1024)

            let sparkline = graph.insetBy(dx: 0, dy: 2)
            let half = sparkline.height / 2
            Sparkline.fillBars(
                values: series.primary,
                in: CGRect(
                    x: sparkline.minX,
                    y: sparkline.midY,
                    width: sparkline.width,
                    height: half
                ),
                colour: style.accent(primaryColour),
                range: 0...scale
            )
            Sparkline.fillBars(
                values: series.secondary,
                in: CGRect(
                    x: sparkline.minX,
                    y: sparkline.minY,
                    width: sparkline.width,
                    height: half
                ),
                colour: style.secondary(secondaryColour),
                range: 0...scale,
                growsDownward: true
            )
        }
        if let value = layout.value(in: bounds) {
            "\(primarySymbol) \(RateFormatter.menuBar(rates.primary))".drawRightAligned(
                in: CGRect(
                    x: value.minX,
                    y: value.midY,
                    width: value.width,
                    height: value.height / 2
                ),
                font: MenuBarMetrics.smallValueFont,
                colour: style.accent(.labelColor)
            )
            "\(secondarySymbol) \(RateFormatter.menuBar(rates.secondary))".drawRightAligned(
                in: CGRect(
                    x: value.minX,
                    y: value.minY,
                    width: value.width,
                    height: value.height / 2
                ),
                font: MenuBarMetrics.smallValueFont,
                colour: style.secondary(.secondaryLabelColor)
            )
        }
    }
}

extension DualRateIndicator {
    /// Both rates share one layout: twenty points of mirrored bars and a
    /// two-line column of numbers.
    private static func layout(_ parts: ModuleParts) -> IndicatorLayout {
        IndicatorLayout(parts: parts, graphWidth: 20, valueWidth: 52, gap: 2)
    }

    static func network(parts: ModuleParts) -> DualRateIndicator {
        DualRateIndicator(
            module: .network,
            layout: layout(parts),
            rates: { state in
                state.snapshot?.network.map { ($0.downloadRate, $0.uploadRate) }
            },
            history: { ($0.download, $0.upload) },
            primaryColour: Palette.networkDown,
            secondaryColour: Palette.networkUp,
            primarySymbol: "↓",
            secondarySymbol: "↑",
            primaryName: "download",
            secondaryName: "upload"
        )
    }

    static func disk(parts: ModuleParts) -> DualRateIndicator {
        DualRateIndicator(
            module: .disk,
            layout: layout(parts),
            rates: { state in
                state.snapshot?.diskActivity.map { ($0.readRate, $0.writeRate) }
            },
            history: { ($0.diskRead, $0.diskWrite) },
            primaryColour: Palette.disk,
            secondaryColour: Palette.cpuEfficiency,
            primarySymbol: "R",
            secondarySymbol: "W",
            primaryName: "read",
            secondaryName: "write"
        )
    }
}
