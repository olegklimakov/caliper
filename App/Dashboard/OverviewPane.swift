import CaliperHistory
import SwiftUI

/// Every metric on one time axis, under one cursor.
///
/// The question the single-metric panes cannot answer: the temperature climbed
/// *here* — what were the CPU and the memory doing at that moment? All the
/// series are already recorded into buckets aligned to absolute time, so they
/// line up without resampling; what was missing was a view that reads them
/// together and a cursor that means the same instant in all of them.
struct OverviewPane: View {
    let metrics: LiveMetrics
    let history: HistoryReader?
    /// Handed in by the preview harness, which renders off-screen and can
    /// neither wait for a query nor drag a cursor.
    private let preloaded: DashboardHistory?

    @State private var span: HistorySpan = .day
    @State private var cursor: Date?
    @State private var loader: DashboardHistory?

    /// The modules, in the sidebar's order, so the stack reads the same way the
    /// rest of the window does.
    private static let modules = MenuBarModule.allCases

    /// What a process-bucket lookup depends on: which moment, and how far back
    /// the history is kept. Changing either has to ask again.
    private struct Lookup: Equatable {
        let moment: Date?
        let retention: ProcessRetention
    }

    /// How many of the bucket's processes the pane has room for. The rest are
    /// still recorded, and the footer says so rather than letting the list read
    /// as the whole bucket.
    private static let shownConsumers = 5

    /// How long the process history is kept, so the readout knows which moments
    /// are still stored.
    private let processRetention: ProcessRetention

    init(metrics: LiveMetrics, history: HistoryReader?, processRetention: ProcessRetention) {
        self.metrics = metrics
        self.history = history
        self.processRetention = processRetention
        self.preloaded = nil
    }

    init(metrics: LiveMetrics, preloaded: DashboardHistory, cursor: Date) {
        self.metrics = metrics
        self.history = nil
        // Never used: the preview's bucket is handed in already read.
        self.processRetention = .week
        self.preloaded = preloaded
        _cursor = State(initialValue: cursor)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Overview — \(span.title)")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                SpanPicker(span: $span)
            }

            caption

            content

            consumers
        }
        .padding(20)
        // Taller than the single-metric pane's minimum, and deliberately: five
        // stacked charts and the readout under them stop being readable below
        // this, so the window is not allowed to get there while the overview is
        // showing.
        .frame(minWidth: 560, minHeight: 560, alignment: .topLeading)
        .task(id: span) {
            let loader = loader ?? preloaded ?? DashboardHistory(reader: history)
            self.loader = loader
            loader.load(Self.modules.map { MetricPresentation(module: $0).series }, span: span)
        }
        // `cursor` is already snapped to a bucket, so a drag across hundreds of
        // pixels inside one asks the store once.
        .task(id: Lookup(moment: inspectedMoment, retention: processRetention)) {
            loader?.inspect(inspectedMoment, retention: processRetention)
        }
        // Not in the task above, which also runs on first appear and would
        // throw away a cursor the preview harness had just set. A bucket of one
        // span is not a bucket of another, so the moment cannot survive the
        // change.
        .onChange(of: span) { cursor = nil }
        .onReceive(NotificationCenter.default.publisher(for: .historyDidChange)) {
            _ in loader?.reload()
        }
        .onDisappear { loader?.stop() }
    }

    /// Which bucket the readout is showing: the cursor's, or — with no cursor —
    /// the most recent one that has anything in it.
    ///
    /// At rest the question "what is running" still has an answer, and giving
    /// it means the readout is always on screen rather than appearing when a
    /// drag starts and shoving the charts around.
    private var inspectedMoment: Date? {
        guard let slice = active?.slice else { return nil }
        return inspected(in: slice) ?? slice.latestRecorded
    }

    /// The loader in use. `loader` is only assigned once the view's task has
    /// run, which it never does under `ImageRenderer`; a preloaded one is
    /// already complete and can be read straight away.
    private var active: DashboardHistory? { loader ?? preloaded }

    /// The cursor, if the moment it pins is still inside the loaded range.
    ///
    /// The window keeps moving: a moment pinned twenty minutes ago falls off
    /// the left of an hour-wide span the next time it reloads, and a rule drawn
    /// past the end of the axis with every value reading "—" is worse than no
    /// cursor at all.
    private func inspected(in slice: HistorySlice) -> Date? {
        guard let cursor, slice.cursorRange?.contains(cursor) == true else { return nil }
        return cursor
    }

    @ViewBuilder
    private var caption: some View {
        // Nothing to scrub is nothing to say: over a placeholder, an invitation
        // to drag across a chart is an invitation to an interaction that branch
        // does not have.
        if active?.slice != nil {
            Text(captionText)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    /// What the line under the header says — and, because it is the whole
    /// answer in one sentence, what VoiceOver reads off the charts.
    private var captionText: String {
        guard let slice = active?.slice, let cursor = inspected(in: slice) else {
            // Both ways in are named: the drag was the only one until the
            // charts became focusable, and it is the one a keyboard cannot use.
            return "Drag across a chart, or press the arrow keys, to read every metric over one bucket"
        }
        return bucketLabel(cursor, in: slice, span: span)
    }

    @ViewBuilder
    private var content: some View {
        if let slice = active?.slice {
            // The rows share whatever height the window has rather than sitting
            // at a fixed one and being clipped — and not in a `ScrollView`,
            // which `ImageRenderer` draws as blank and would cost this pane the
            // only visual check the project has. The spacing is what keeps one
            // chart's bottom axis label clear of the next one's top.
            VStack(spacing: 16) {
                ForEach(Array(Self.modules.enumerated()), id: \.element) { index, module in
                    row(module, slice: slice, showsTimeAxis: index == Self.modules.count - 1)
                }
            }
            // One tab stop for the five of them: they are one picture under one
            // cursor, and five stops for one control would be noise.
            .chartCursorKeys($cursor, in: slice)
            // `contain`, not the default: a label on a container is inherited
            // by every child that has none of its own, and the module titles
            // and their values were all being read out as this one sentence.
            // No `accessibilityValue` either — VoiceOver treats value as a
            // control's affordance and does not reliably speak it on a group,
            // and the caption saying the same thing is already in the tree.
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Every metric over the \(span.title)")
        } else {
            HistoryPlaceholder(state: active?.state)
        }
    }

    /// What was running over the bucket under the cursor.
    ///
    /// Deliberately a list for one bucket and never a series. Only the top ten
    /// are stored, so a process missing from a bucket means "not in the top
    /// ten", not "idle"; a line drawn through that gap would be a lie the UI
    /// told confidently. The heading says which bucket it is for and that it is
    /// a top ten, so the list cannot be read as the whole truth about the
    /// machine at that moment.
    @ViewBuilder
    private var consumers: some View {
        if active?.slice != nil {
            VStack(alignment: .leading, spacing: 4) {
                if let bucket = active?.consumers, !bucket.isEmpty {
                    Text(
                        "Top consumers · \(bucket.start.formatted(bucketFormat))–\(bucket.end.formatted(bucketFormat)) · \(bucket.tier.label) bucket"
                    )
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)

                    // Both rankings, side by side, because both are what the
                    // bucket stores. Ordering one list by CPU and printing the
                    // footprint beside it showed the CPU list twice over: a
                    // process holding gigabytes while using no CPU — a browser
                    // left open overnight — was recorded and never once shown.
                    HStack(alignment: .top, spacing: 24) {
                        ranking("By CPU", bucket.consumers) { usage in
                            PercentFormatter.string(usage.cpu, decimals: 1)
                        }
                        ranking("By memory", bucket.byFootprint) { usage in
                            ByteFormatter.memory(usage.footprint)
                        }
                    }

                    // Said outright, because the alternative is a list that
                    // reads as everything that was running. Only the heaviest
                    // are kept, so a process not here was not necessarily idle.
                    Text(
                        "\(min(Self.shownConsumers, bucket.consumers.count)) of each ranking, out of \(bucket.consumers.count) recorded — only the heaviest ten by CPU and by memory are kept"
                    )
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                } else {
                    // Not silence: a bucket with nothing in it is an answer —
                    // the Mac was asleep, the recording is switched off, or the
                    // moment is older than the history is kept for.
                    Text("No processes recorded for this bucket")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            // A fixed height, and this is the whole reason the readout is drawn
            // even with no cursor on the charts. The five charts above are
            // greedy, so a block that appeared when you started scrubbing took
            // its height out of them and the picture you were pointing at
            // jumped under the pointer. Reserved for the full five rows as
            // well, or a bucket that happened to record two processes would
            // resize everything again on the way past.
            .frame(height: Self.consumersHeight, alignment: .topLeading)
        }
    }

    /// Room for the heading, five rows under each ranking, and the footer.
    private static let consumersHeight: CGFloat = 118

    /// One of the bucket's two rankings.
    private func ranking(
        _ title: String,
        _ usage: [ProcessUsage],
        value: @escaping (ProcessUsage) -> String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)

            ForEach(usage.prefix(Self.shownConsumers), id: \.name) { usage in
                HStack(spacing: 8) {
                    Text(usage.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 0)
                    Text(value(usage))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.system(size: 11))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row(_ module: MenuBarModule, slice: HistorySlice, showsTimeAxis: Bool) -> some View {
        let presentation = MetricPresentation(module: module)
        let pinned = inspected(in: slice)
        let sample = pinned.map { slice.bucket(containing: $0) }
            .flatMap { slice.sample(presentation.series, at: $0) }

        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(module.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(reading(presentation, sample: sample, inspecting: pinned != nil, slice: slice))
                    .font(.system(size: 15))
                    .monospacedDigit()
                // The band is why min and max are stored at all: a bucket that
                // averaged 20 % but touched 100 % is not a quiet bucket.
                Text(band(presentation, sample: sample))
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .frame(width: 112, alignment: .leading)

            HistoryChart(
                samples: slice[presentation.series],
                colour: presentation.colour,
                range: presentation.range,
                startsAtZero: presentation.startsAtZero,
                // Forced rather than left to each series' own rows, so the rule
                // drawn at one moment lands on the same x in all five — a
                // series that stopped recording early would otherwise squeeze
                // its chart into a shorter axis.
                timeDomain: slice.start...slice.end,
                showsTimeAxis: showsTimeAxis,
                yAxisValues: 3,
                // Room for the widest label any of these five rows can print —
                // "28,6 MB/s" at 50 points — so every plot is inset by the
                // same amount and the columns of five charts are one column.
                yAxisLabelWidth: 52,
                cursor: pinned,
                onScrub: { moment in
                    cursor = moment.map { slice.bucket(containing: $0) }
                },
                axisLabel: presentation.format
            )
            .frame(minHeight: 56, maxHeight: .infinity)
        }
    }

    /// What the value column says: the inspected bucket's average, the latest
    /// stored one when nothing is being inspected, and an em dash where the
    /// moment has no row at all.
    private func reading(
        _ presentation: MetricPresentation,
        sample: HistorySample?,
        inspecting: Bool,
        slice: HistorySlice
    ) -> String {
        if let sample {
            return presentation.format(sample.aggregate.average)
        }
        // A cursor over a gap — the Mac asleep, or a sensor this machine does
        // not have. Never the neighbouring bucket's value, which would be the
        // readout disagreeing with the gap the chart is drawing.
        if inspecting {
            return "—"
        }
        guard let latest = slice[presentation.series].last else { return "—" }
        return presentation.format(latest.aggregate.average)
    }

    private func band(_ presentation: MetricPresentation, sample: HistorySample?) -> String {
        guard let sample else { return " " }
        return "\(presentation.format(sample.aggregate.minimum))–\(presentation.format(sample.aggregate.maximum))"
    }

    /// Seconds included: a process bucket is thirty seconds wide, and
    /// "11.00–11.00" would not look like a span at all.
    private var bucketFormat: Date.FormatStyle {
        .dateTime.hour().minute().second()
    }

}
