import Charts
import CaliperHistory
import SwiftUI

/// A stored series drawn against real time, with a min–max band behind the
/// average.
///
/// Swift Charts does not leave gaps: sparse rows are points that happen to be
/// far apart, and it joins them, so a Mac asleep overnight came back as a
/// smooth sixteen-hour ramp. Each unbroken stretch is handed over as a series
/// of its own instead.
struct HistoryChart: View {
    /// Split where the record stops — see `HistorySlice.runs(_:)`.
    let runs: [[HistorySample]]
    let colour: Color
    var range: ClosedRange<Double>?
    /// See `chartDomain` for what this decides.
    var startsAtZero = true
    /// Forced when several charts are stacked, so a rule drawn at one moment
    /// lands on the same x in all of them.
    var timeDomain: ClosedRange<Date>?
    var showsTimeAxis = true
    /// Fewer in a stack: a full set in sixty points runs one chart's labels
    /// into the next one's.
    var yAxisValues = 5
    /// Why stacked charts line up at all: Swift Charts insets the plot by
    /// whatever its own labels measure, so "28,6 MB/s" gets a plot twenty
    /// points narrower than "0%", and the same instant lands at a different x
    /// in every row.
    var yAxisLabelWidth: CGFloat?
    var cursor: Date?
    /// Set to make the chart scrubbable. `nil` once the drag leaves the plot,
    /// which is how a cursor gets dismissed.
    var onScrub: ((Date?) -> Void)?
    /// At most this many marks, merged from neighbours. `nil` draws every row.
    ///
    /// A chart cannot show more points than it has pixels, and Swift Charts
    /// allocates per mark: a day of minute buckets is 1440 of them, and two
    /// such charts in 72-point tiles, re-evaluated once a second by the card's
    /// live probe, took the app from 24 MB to 150 MB in nine minutes and then
    /// killed it. The menu bar's own sparklines have thinned for the same
    /// reason since Phase 4 — see `Downsample.peaks`.
    var maximumPoints: Int?
    var axisLabel: (Double) -> String

    /// Thinned per run, never across one: a gap is the whole reason runs are
    /// separate, and merging over it would draw the ramp this chart exists to
    /// refuse.
    private var drawnRuns: [[HistorySample]] {
        guard let maximumPoints, maximumPoints > 0 else { return runs }
        let total = runs.reduce(0) { $0 + $1.count }
        guard total > maximumPoints else { return runs }
        return runs.map { run in
            // Proportional, so a short run keeps at least one point and the
            // long ones give up the rest.
            Self.thin(run, to: max(1, run.count * maximumPoints / total))
        }
    }

    /// Peaks kept, means re-weighted: a spike that lasted one bucket is what a
    /// monitor exists to show, and averaging the band away is what would hide
    /// it.
    private static func thin(_ run: [HistorySample], to count: Int) -> [HistorySample] {
        guard run.count > count else { return run }
        return (0..<count).map { slot in
            let slice = run[run.count * slot / count..<run.count * (slot + 1) / count]
            let readings = slice.reduce(0) { $0 + $1.aggregate.count }
            return HistorySample(
                series: run[0].series,
                timestamp: slice.first?.timestamp ?? run[0].timestamp,
                aggregate: Aggregate(
                    minimum: slice.map(\.aggregate.minimum).min() ?? 0,
                    average: readings > 0
                        ? slice.reduce(0) { $0 + $1.aggregate.average * Double($1.aggregate.count) }
                            / Double(readings)
                        : 0,
                    maximum: slice.map(\.aggregate.maximum).max() ?? 0,
                    count: readings
                )
            )
        }
    }

    var body: some View {
        Chart {
            // `series:` keeps one run from being joined to the next. It
            // groups only; the colour is set outright, so no legend follows.
            ForEach(Array(drawnRuns.enumerated()), id: \.offset) { index, run in
                ForEach(run, id: \.timestamp) { sample in
                    AreaMark(
                        x: .value("Time", sample.timestamp),
                        yStart: .value("Low", sample.aggregate.minimum),
                        yEnd: .value("High", sample.aggregate.maximum),
                        series: .value("Run", index)
                    )
                    .foregroundStyle(colour.opacity(0.18))

                    LineMark(
                        x: .value("Time", sample.timestamp),
                        y: .value("Average", sample.aggregate.average),
                        series: .value("Run", index)
                    )
                    .foregroundStyle(colour)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                }

                // A line with no length draws nothing, so a run of one bucket
                // would be invisible.
                if run.count == 1, let only = run.first {
                    PointMark(
                        x: .value("Time", only.timestamp),
                        y: .value("Average", only.aggregate.average)
                    )
                    .foregroundStyle(colour)
                    .symbolSize(12)
                }
            }

            if let cursor {
                RuleMark(x: .value("Time", cursor))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .chartXAxis {
            AxisMarks { value in
                // Gridlines stay even when the labels are off: stacked charts
                // read as one picture only if their verticals agree.
                AxisGridLine().foregroundStyle(Color(Palette.gridLine))
                if showsTimeAxis {
                    // Styling the text, not the `AxisValueLabel` wrapper: the
                    // wrapper ignores `foregroundStyle` and the times come out
                    // in the accent colour, reading as links.
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(date, format: timeFormat)
                                .font(.system(size: 10))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                // A tick near the right edge gets less width
                                // than the time needs, and "10…" is worse than
                                // reaching past the gridline.
                                .fixedSize()
                        }
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: yAxisValues)) { value in
                AxisGridLine().foregroundStyle(Color(Palette.gridLine))
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(axisLabel(number))
                            .font(.system(size: 10))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: yAxisLabelWidth, alignment: .leading)
                    }
                }
            }
        }
        .chartYScale(domain: range ?? defaultDomain)
        .modifier(TimeDomain(range: timeDomain))
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            if let onScrub {
                GeometryReader { geometry in
                    Rectangle()
                        .fill(.clear)
                        .contentShape(Rectangle())
                        .gesture(
                            // Zero distance: a click places the cursor rather
                            // than waiting to be dragged into one.
                            DragGesture(minimumDistance: 0).onChanged { drag in
                                scrub(to: drag.location, proxy: proxy, geometry: geometry, report: onScrub)
                            }
                        )
                }
            }
        }
    }

    private func scrub(
        to point: CGPoint,
        proxy: ChartProxy,
        geometry: GeometryProxy,
        report: (Date?) -> Void
    ) {
        guard let plot = proxy.plotFrame else { return }
        // Gesture coordinates are the overlay's; the plot sits inside it,
        // inset by the axis labels.
        let x = point.x - geometry[plot].origin.x
        report(proxy.value(atX: x, as: Date.self))
    }

    /// Every bucket, runs run together: the scale asks about the whole span,
    /// and where the record stops matters only to the line.
    private var samples: [HistorySample] { runs.flatMap { $0 } }

    /// The band decides the scale here, because the band is what is drawn.
    private var defaultDomain: ClosedRange<Double> {
        chartDomain(
            lowest: samples.map(\.aggregate.minimum).min(),
            highest: samples.map(\.aggregate.maximum).max(),
            startsAtZero: startsAtZero
        )
    }

    private var timeFormat: Date.FormatStyle {
        let span =
            timeDomain.map { $0.upperBound.timeIntervalSince($0.lowerBound) }
            ?? (samples.last?.timestamp.timeIntervalSince(samples.first?.timestamp ?? Date())) ?? 0
        return span > 3 * 24 * 3600
            ? .dateTime.day().month(.abbreviated)
            : .dateTime.hour().minute()
    }
}

/// A modifier because `chartXScale(domain:)` has no "as it comes" value of the
/// same type to pass, and a chart with no samples has no range to force.
private struct TimeDomain: ViewModifier {
    let range: ClosedRange<Date>?

    func body(content: Content) -> some View {
        if let range, range.lowerBound < range.upperBound {
            content.chartXScale(domain: range)
        } else {
            content
        }
    }
}

/// One stored series at a glance: a filled line, no axes, no scrub. The
/// dashboard's secondary charts, for the neighbouring metrics that explain why
/// the main one moved.
///
/// A view of its own rather than four more flags on `HistoryChart`, which
/// already carries eight for the stacked case.
struct MiniChart: View {
    let runs: [[HistorySample]]
    let colour: Color
    var range: ClosedRange<Double>?
    var startsAtZero = true

    var body: some View {
        let domain = range ?? defaultDomain

        Chart {
            ForEach(Array(runs.enumerated()), id: \.offset) { index, run in
                ForEach(run, id: \.timestamp) { sample in
                    // Anchored to the foot of the scale, not to zero: a
                    // temperature domain starts around 36 °C, and an area
                    // reaching for zero spills out of the card.
                    AreaMark(
                        x: .value("Time", sample.timestamp),
                        yStart: .value("Floor", domain.lowerBound),
                        yEnd: .value("Average", sample.aggregate.average),
                        series: .value("Run", index)
                    )
                    // At this height a solid fill reads as a block of colour
                    // with a line on it.
                    .foregroundStyle(
                        .linearGradient(
                            colors: [colour.opacity(0.35), colour.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                    LineMark(
                        x: .value("Time", sample.timestamp),
                        y: .value("Average", sample.aggregate.average),
                        series: .value("Run", index)
                    )
                    .foregroundStyle(colour)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                }

                // As above: a run of one still has to be visible.
                if run.count == 1, let only = run.first {
                    PointMark(
                        x: .value("Time", only.timestamp),
                        y: .value("Average", only.aggregate.average)
                    )
                    .foregroundStyle(colour)
                    .symbolSize(10)
                }
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: domain)
        .chartLegend(.hidden)
    }

    /// Averages, not extremes: with no band to draw, a domain sized to the
    /// maxima flattens the line into the bottom third of a chart this short.
    private var defaultDomain: ClosedRange<Double> {
        let averages = runs.flatMap { $0 }.map(\.aggregate.average)
        return chartDomain(lowest: averages.min(), highest: averages.max(), startsAtZero: startsAtZero)
    }
}

/// A scale with a little air above and below, so the line is not drawn along an
/// edge.
///
/// `startsAtZero` is the difference between a rate and a temperature: a rate of
/// nothing is a real reading, while 0 °C is somewhere this machine has never
/// been and anchoring there spends two thirds of the plot on empty space. The
/// floor of two is in that branch's unit — today only temperature — so a die
/// steady inside one degree still gets a chart rather than a flat line.
func chartDomain(lowest: Double?, highest: Double?, startsAtZero: Bool) -> ClosedRange<Double> {
    let top = highest ?? 1
    guard !startsAtZero else { return 0...Swift.max(top, 1) }

    let bottom = lowest ?? 0
    let padding = Swift.max((top - bottom) * 0.15, 2)
    return (bottom - padding)...(top + padding)
}

extension View {
    /// Makes a chart, or a stack of them, scrubbable from the keyboard — a
    /// drag alone is unreachable to anyone not using a pointer.
    ///
    /// Applied to the *picture* rather than to each chart, so the overview's
    /// five rows share one cursor and one tab stop. The caller adds
    /// `.accessibilityLabel` and `.accessibilityValue`.
    func chartCursorKeys(_ cursor: Binding<Date?>, in slice: HistorySlice) -> some View {
        modifier(ChartCursorKeys(cursor: cursor, slice: slice))
    }
}

private struct ChartCursorKeys: ViewModifier {
    let cursor: Binding<Date?>
    let slice: HistorySlice

    func body(content: Content) -> some View {
        content
            // Before `focusable`, never after: the ring reads `\.isFocused`,
            // and only a view *inside* the focusable one is told that.
            .overlay { ChartFocusRing() }
            // Tab reaches a `focusable` view only with Full Keyboard Access on,
            // which is off by default — but a click lands in one, so scrubbing
            // once with the pointer leaves the arrows working from there.
            .focusable()
            // At the size of the whole picture the system ring reads as an
            // alert rather than "the arrow keys go here".
            .focusEffectDisabled()
            .onKeyPress(.leftArrow) { step(-1) }
            .onKeyPress(.rightArrow) { step(1) }
            // The same way out a drag has.
            .onKeyPress(.escape) {
                guard cursor.wrappedValue != nil else { return .ignored }
                cursor.wrappedValue = nil
                return .handled
            }
    }

    /// Ignored rather than handled with nowhere to move to — swallowing the
    /// key would only make the window feel stuck.
    private func step(_ buckets: Int) -> KeyPress.Result {
        guard let next = slice.bucket(from: cursor.wrappedValue, steppedBy: buckets) else {
            return .ignored
        }
        cursor.wrappedValue = next
        return .handled
    }
}

/// Says where the arrow keys will land, quietly — unless Increase Contrast is
/// on, which is the setting that exists to reject a 45 % hairline.
///
/// A view of its own so it sits *inside* the focusable chart and can read
/// `\.isFocused`. Do not swap that for a `@FocusState` bound with `.focused`:
/// with that modifier applied SwiftUI reports the chart as unfocused through
/// both the binding and the environment while still drawing a focus effect
/// around it, so the ring never appears.
private struct ChartFocusRing: View {
    @Environment(\.isFocused) private var focused
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let isEmphasised = contrast == .increased
        return RoundedRectangle(cornerRadius: PanelMetrics.cardRadius, style: .continuous)
            .strokeBorder(
                Color(nsColor: .controlAccentColor).opacity(isEmphasised ? 1 : 0.45),
                lineWidth: isEmphasised ? 2 : 1
            )
            .padding(-6)
            .opacity(focused ? 1 : 0)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: focused)
            .allowsHitTesting(false)
    }
}

/// A span, never an instant: a die lags the load that heated it by tens of
/// seconds, so "at 14:32:10" claims a precision the machine does not have.
func bucketLabel(_ moment: Date, in slice: HistorySlice, span: HistorySpan) -> String {
    let end = moment.addingTimeInterval(TimeInterval(slice.tier.seconds))
    let momentFormat: Date.FormatStyle =
        span.seconds > 24 * 3600
        ? .dateTime.day().month(.abbreviated).hour().minute()
        : .dateTime.hour().minute()
    return "\(moment.formatted(momentFormat))–\(end.formatted(.dateTime.hour().minute())) · \(slice.tier.label) bucket"
}
