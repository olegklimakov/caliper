import Charts
import CaliperHistory
import SwiftUI

/// A stored series drawn against real time.
///
/// Time on the x-axis, not sample index: the app is not always running, and
/// plotting stored buckets side by side would draw a night the Mac spent asleep
/// as a continuous line. Swift Charts leaves a gap where there is no data, which
/// is the honest picture.
///
/// The band between each bucket's minimum and maximum is drawn behind the
/// average, because that is the whole reason those columns are stored: an hour
/// that averaged 20 % but touched 100 % is not the same hour as a flat 20 %.
struct HistoryChart: View {
    let samples: [HistorySample]
    let colour: Color
    var range: ClosedRange<Double>?
    /// Whether zero belongs on the axis. A rate of nothing is meaningful, so
    /// its chart starts at zero; a temperature of 0 °C is not somewhere this
    /// machine has ever been, and anchoring there wastes two thirds of the
    /// chart on empty space.
    var startsAtZero = true
    /// Forced when several charts are stacked, so a rule drawn at one moment
    /// lands on the same x in all of them. Left to the data otherwise.
    var timeDomain: ClosedRange<Date>?
    /// Off for every chart but the bottom one in a stack, where five copies of
    /// the same times would only be noise.
    var showsTimeAxis = true
    /// How many values the y-axis labels. Fewer when the chart is one of a
    /// stack: a full set in sixty points runs the top of one chart's labels
    /// into the bottom of the next one's.
    var yAxisValues = 5
    /// Width reserved for those labels. Set when several charts are stacked,
    /// and the reason their time axes line up at all: Swift Charts insets the
    /// plot by whatever its own labels measure, so a row labelled "28,6 MB/s"
    /// gets a plot twenty points narrower than one labelled "0%", and the same
    /// instant then lands at a different x in every row. Left to the text
    /// otherwise, where nothing has to agree with anything.
    var yAxisLabelWidth: CGFloat?
    /// The moment being inspected, marked with a rule.
    var cursor: Date?
    /// Set to make the chart scrubbable. Called with the moment under the
    /// pointer, or `nil` once the drag leaves the plot — which is how a cursor
    /// gets dismissed.
    var onScrub: ((Date?) -> Void)?
    var axisLabel: (Double) -> String

    var body: some View {
        Chart {
            ForEach(samples, id: \.timestamp) { sample in
                AreaMark(
                    x: .value("Time", sample.timestamp),
                    yStart: .value("Low", sample.aggregate.minimum),
                    yEnd: .value("High", sample.aggregate.maximum)
                )
                .foregroundStyle(colour.opacity(0.18))

                LineMark(
                    x: .value("Time", sample.timestamp),
                    y: .value("Average", sample.aggregate.average)
                )
                .foregroundStyle(colour)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
            }

            if let cursor {
                RuleMark(x: .value("Time", cursor))
                    .foregroundStyle(.secondary)
                    .lineStyle(StrokeStyle(lineWidth: 1))
            }
        }
        .chartXAxis {
            AxisMarks { value in
                // The gridlines stay on every chart even when the labels are
                // off: stacked charts read as one picture only if their
                // verticals agree.
                AxisGridLine().foregroundStyle(Color(Palette.gridLine))
                if showsTimeAxis {
                    // Styling the label's own text, not the `AxisValueLabel`
                    // wrapper: the wrapper ignores the foreground style and the
                    // times come out in the accent colour, reading as links.
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(date, format: timeFormat)
                                .font(.system(size: 10))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                // A tick close to the right edge is given less
                                // width than the time needs, and a clock
                                // truncated to "10…" is worse than one that
                                // reaches past its gridline.
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
                            // Zero minimum distance: a click should place the
                            // cursor, not wait to be dragged into one.
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
        // The gesture's coordinates are the overlay's; the plot sits inside it,
        // inset by the axis labels.
        let x = point.x - geometry[plot].origin.x
        report(proxy.value(atX: x, as: Date.self))
    }

    /// The band decides the scale here, because the band is what is drawn.
    private var defaultDomain: ClosedRange<Double> {
        chartDomain(
            lowest: samples.map(\.aggregate.minimum).min(),
            highest: samples.map(\.aggregate.maximum).max(),
            startsAtZero: startsAtZero
        )
    }

    /// Hours and minutes over short spans, days over long ones.
    private var timeFormat: Date.FormatStyle {
        let span =
            timeDomain.map { $0.upperBound.timeIntervalSince($0.lowerBound) }
            ?? (samples.last?.timestamp.timeIntervalSince(samples.first?.timestamp ?? Date())) ?? 0
        return span > 3 * 24 * 3600
            ? .dateTime.day().month(.abbreviated)
            : .dateTime.hour().minute()
    }
}

/// Applies a fixed x domain, or leaves the chart to work one out.
///
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

/// One stored series at a glance: a filled line, no axes, no scrub.
///
/// The secondary charts on the dashboard. A chart of one metric rarely answers
/// *why* — the CPU climbed, and the question is at once what memory and the die
/// were doing — so each pane carries two of these for the neighbours that most
/// often explain it.
///
/// A view of its own rather than `HistoryChart` with more flags. That one
/// already carries eight knobs for the stacked case, and this wants no
/// gridlines, no labels, no min–max band and no cursor: four more flags to say
/// "draw almost none of this" is the larger change, not the smaller one.
struct MiniChart: View {
    let samples: [HistorySample]
    let colour: Color
    var range: ClosedRange<Double>?
    var startsAtZero = true

    var body: some View {
        let domain = range ?? defaultDomain

        Chart(samples, id: \.timestamp) { sample in
            AreaMark(
                x: .value("Time", sample.timestamp),
                // Anchored to the foot of the scale, not left to fill to zero.
                // A temperature chart's domain starts around 36 °C, and an area
                // that reaches for zero is drawn well below the plot — it spills
                // out of the card and over whatever is under it.
                yStart: .value("Floor", domain.lowerBound),
                yEnd: .value("Average", sample.aggregate.average)
            )
            // A gradient rather than a flat wash: at this height a solid fill
            // reads as a block of colour with a line on top of it.
            .foregroundStyle(
                .linearGradient(
                    colors: [colour.opacity(0.35), colour.opacity(0.02)],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )

            LineMark(
                x: .value("Time", sample.timestamp),
                y: .value("Average", sample.aggregate.average)
            )
            .foregroundStyle(colour)
            .lineStyle(StrokeStyle(lineWidth: 1.5))
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: domain)
        .chartLegend(.hidden)
    }

    /// The averages decide the scale here, not the extremes: without a band to
    /// draw, a domain sized to the maxima would flatten the line into the
    /// bottom third of a chart this short.
    private var defaultDomain: ClosedRange<Double> {
        let averages = samples.map(\.aggregate.average)
        return chartDomain(lowest: averages.min(), highest: averages.max(), startsAtZero: startsAtZero)
    }
}

/// A scale with a little air above and below, so the line is not drawn along an
/// edge.
///
/// Written once for both charts. `startsAtZero` is the whole difference between
/// a rate and a temperature: a rate of nothing is a real reading and belongs on
/// the axis, while 0 °C is somewhere this machine has never been, and anchoring
/// there would spend two thirds of the plot on empty space.
///
/// The floor of two is in the unit of whichever series takes this branch, and
/// today that is only temperature: a die that held steady inside one degree
/// still gets a chart, rather than a flat line filling the frame.
func chartDomain(lowest: Double?, highest: Double?, startsAtZero: Bool) -> ClosedRange<Double> {
    let top = highest ?? 1
    guard !startsAtZero else { return 0...Swift.max(top, 1) }

    let bottom = lowest ?? 0
    let padding = Swift.max((top - bottom) * 0.15, 2)
    return (bottom - padding)...(top + padding)
}

extension View {
    /// Makes a chart, or a stack of them, scrubbable from the keyboard.
    ///
    /// Phase 5's accessibility pass recorded that the charts "have no
    /// interaction to reach". They gained one in Stage A and it was a drag,
    /// which is the same note with an extra step: a pointer-only control is
    /// still unreachable to anyone not using a pointer.
    ///
    /// Applied to whatever the *picture* is rather than to each chart. The
    /// overview's five rows share one cursor and are one picture, so they get
    /// one tab stop between them; a single-metric pane's chart is its own.
    ///
    /// The caller adds `.accessibilityLabel` and `.accessibilityValue`: both
    /// panes already build that sentence for their own caption, and VoiceOver
    /// should read what is on screen rather than a second description written
    /// only for it.
    func chartCursorKeys(_ cursor: Binding<Date?>, in slice: HistorySlice) -> some View {
        modifier(ChartCursorKeys(cursor: cursor, slice: slice))
    }
}

private struct ChartCursorKeys: ViewModifier {
    let cursor: Binding<Date?>
    let slice: HistorySlice

    @FocusState private var focused: Bool
    /// The two accessibility modes a focus indicator has to answer to: one asks
    /// for it louder, the other asks for it not to move.
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content
            .focusable()
            .focused($focused)
            // The system ring is drawn around whatever is focusable, and what
            // is focusable here is the whole picture — five stacked charts, or
            // a pane-sized one. At that size the ring stops reading as "the
            // arrow keys go here" and starts reading as an alert, so it is
            // replaced by a hairline in the same accent below.
            .focusEffectDisabled()
            .overlay { focusRing }
            // A click takes focus as well as placing the cursor, so scrubbing
            // once with the pointer leaves the arrows working from there.
            //
            // This is why: Tab reaches a `focusable` view only when Full
            // Keyboard Access is on, and it is off by default, so arrows that
            // needed a trip to System Settings first would be the accessibility
            // note again in a new form. Taking the window's initial focus off
            // the sidebar instead was tried and is worse — a split view's
            // sidebar is where macOS puts it, and arrow keys through a list of
            // metrics is the behaviour that would have been stolen.
            //
            // `simultaneousGesture`, because the chart's own drag has already
            // claimed the click and a plain `onTapGesture` would never fire.
            .simultaneousGesture(TapGesture().onEnded { focused = true })
            .onKeyPress(.leftArrow) { step(-1) }
            .onKeyPress(.rightArrow) { step(1) }
            // The same way out a drag has: leaving the plot dismisses the
            // cursor, and escape is what that looks like from a keyboard.
            .onKeyPress(.escape) {
                guard cursor.wrappedValue != nil else { return .ignored }
                cursor.wrappedValue = nil
                return .handled
            }
    }

    /// Says where the arrow keys will land without shouting it. Outside the
    /// plot by a few points so it never crowds the axis labels, and faded in so
    /// that clicking into a chart does not blink a box into existence.
    ///
    /// Quiet is a default, not a rule: with Increase Contrast on, a hairline at
    /// 45 % is exactly the indicator that setting exists to reject, so the ring
    /// goes back to full strength and full weight. Reduce Motion drops the
    /// fade — the ring still appears, it just stops travelling to get there.
    private var focusRing: some View {
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

    /// Ignored rather than handled when the slice holds no whole bucket: there
    /// is nothing to move to, and swallowing the key would only make the
    /// window feel stuck.
    private func step(_ buckets: Int) -> KeyPress.Result {
        guard let next = slice.bucket(from: cursor.wrappedValue, steppedBy: buckets) else {
            return .ignored
        }
        cursor.wrappedValue = next
        return .handled
    }
}

/// How a bucket is written wherever one is read out: a span, never an instant.
///
/// A die lags the load that heated it by tens of seconds, so "at 14:32:10"
/// would claim a precision the machine does not have. The day is worth saying
/// once the span is wide enough for the cursor to be on a different one.
func bucketLabel(_ moment: Date, in slice: HistorySlice, span: HistorySpan) -> String {
    let end = moment.addingTimeInterval(TimeInterval(slice.tier.seconds))
    let momentFormat: Date.FormatStyle =
        span.seconds > 24 * 3600
        ? .dateTime.day().month(.abbreviated).hour().minute()
        : .dateTime.hour().minute()
    return "\(moment.formatted(momentFormat))–\(end.formatted(.dateTime.hour().minute())) · \(slice.tier.label) bucket"
}
