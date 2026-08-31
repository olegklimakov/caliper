import CaliperHistory
import SwiftUI

/// Every metric on one time axis, under one cursor — the question the
/// single-metric panes cannot answer: the temperature climbed *here*, what were
/// the CPU and the memory doing? The series are recorded into buckets aligned
/// to absolute time, so they line up without resampling.
struct OverviewPane: View {
    let metrics: LiveMetrics
    let history: HistoryReader?
    /// Handed in by the preview harness, which renders off-screen and can
    /// neither wait for a query nor drag a cursor.
    private let preloaded: DashboardHistory?

    @State private var span: HistorySpan = .day
    @State private var cursor: Date?
    @State private var loader: DashboardHistory?

    /// In the sidebar's order, so the stack reads the way the window does.
    private static let modules = MenuBarModule.allCases

    /// What a process-bucket lookup depends on; changing any of it asks
    /// again.
    private struct Lookup: Equatable {
        let moment: Date?
        let retention: ProcessRetention
        /// A missing bucket means something different when nobody is
        /// recording.
        let isRecording: Bool
    }

    /// How many the pane has room for. The rest are still recorded, and the
    /// footer says so rather than letting the list read as the whole bucket.
    private static let shownConsumers = 5

    /// Says which moments are still stored.
    private let processRetention: ProcessRetention
    /// Whether the process history is being written at all.
    private let recordsProcesses: Bool
    /// A consumer row opens its process's card. The store keys consumers by
    /// name alone, so the card may open on a process that no longer runs —
    /// which is a valid card.
    private let openCard: (ProcessCardTarget) -> Void

    init(
        metrics: LiveMetrics,
        history: HistoryReader?,
        processRetention: ProcessRetention,
        recordsProcesses: Bool,
        openCard: @escaping (ProcessCardTarget) -> Void
    ) {
        self.metrics = metrics
        self.history = history
        self.processRetention = processRetention
        self.recordsProcesses = recordsProcesses
        self.openCard = openCard
        self.preloaded = nil
    }

    init(metrics: LiveMetrics, preloaded: DashboardHistory, cursor: Date) {
        self.metrics = metrics
        self.history = nil
        // Never used: the preview's bucket is handed in already read.
        self.processRetention = .week
        self.recordsProcesses = true
        self.openCard = { _ in }
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
        // Taller than the single-metric pane's minimum: five stacked charts
        // and the readout under them stop being readable below this.
        .frame(minWidth: 560, minHeight: 560, alignment: .topLeading)
        .task(id: span) {
            let loader = loader ?? preloaded ?? DashboardHistory(reader: history)
            self.loader = loader
            loader.load(Self.modules.map { MetricPresentation(module: $0).series }, span: span)
        }
        // `cursor` is already snapped to a bucket, so a drag across hundreds of
        // pixels inside one asks the store once.
        .task(
            id: Lookup(
                moment: inspectedMoment,
                retention: processRetention,
                isRecording: recordsProcesses
            )
        ) {
            loader?.inspect(
                inspectedMoment,
                retention: processRetention,
                isRecording: recordsProcesses
            )
        }
        // Not in the task above, which also runs on first appear and would
        // throw away a cursor the preview harness had just set.
        .onChange(of: span) { cursor = nil }
        .onReceive(NotificationCenter.default.publisher(for: .historyDidChange)) {
            _ in loader?.reload()
        }
        .onDisappear { loader?.stop() }
    }

    /// The cursor's bucket, or the most recent one with anything in it. At rest
    /// "what is running" still has an answer, and giving it keeps the readout on
    /// screen rather than appearing mid-drag and shoving the charts around.
    private var inspectedMoment: Date? {
        guard let slice = active?.slice else { return nil }
        return inspected(in: slice) ?? slice.latestRecorded
    }

    /// The loader in use. `loader` is only assigned once the view's task has
    /// run, which it never does under `ImageRenderer`; a preloaded one is
    /// already complete and can be read straight away.
    private var active: DashboardHistory? { loader ?? preloaded }

    /// The cursor, if the moment it pins is still inside the loaded range: the
    /// window keeps moving, and a rule past the end of the axis with every value
    /// reading "—" is worse than no cursor.
    private func inspected(in slice: HistorySlice) -> Date? {
        guard let cursor, slice.cursorRange?.contains(cursor) == true else { return nil }
        return cursor
    }

    @ViewBuilder
    private var caption: some View {
        // Over a placeholder, an invitation to drag is an invitation to an
        // interaction that branch does not have.
        if active?.slice != nil {
            Text(captionText)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    /// The line under the header, and what VoiceOver reads off the charts.
    private var captionText: String {
        guard let slice = active?.slice, let cursor = inspected(in: slice) else {
            // Both ways in are named: a drag is the one a keyboard cannot
            // use.
            return "Drag across a chart, or press the arrow keys, to read every metric over one bucket"
        }
        return bucketLabel(cursor, in: slice, span: span)
    }

    @ViewBuilder
    private var content: some View {
        if let slice = active?.slice {
            // The rows share the window's height rather than being clipped —
            // and not in a `ScrollView`, which `ImageRenderer` draws blank,
            // costing this pane the project's only visual check. The spacing
            // keeps one chart's bottom axis label clear of the next one's top.
            VStack(spacing: 16) {
                ForEach(Array(Self.modules.enumerated()), id: \.element) { index, module in
                    row(module, slice: slice, showsTimeAxis: index == Self.modules.count - 1)
                }
            }
            // One picture under one cursor, so one tab stop.
            .chartCursorKeys($cursor, in: slice)
            // `contain`, not the default: a container's label is inherited by
            // every child without one, so the module titles and values all read
            // out as this one sentence. No `accessibilityValue` either —
            // VoiceOver does not reliably speak value on a group.
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Every metric over the \(span.title)")
        } else {
            HistoryPlaceholder(state: active?.state)
        }
    }

    /// What was running over the bucket under the cursor: one bucket, never a
    /// series. Only the top ten are stored, so a missing process means "not in
    /// the top ten", not "idle" — which is why the heading says so.
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

                    // Both rankings, because both are what the bucket stores.
                    // One list ordered by CPU with the footprint printed beside
                    // it never shows a process holding gigabytes at no CPU — a
                    // browser left open overnight.
                    HStack(alignment: .top, spacing: 24) {
                        ranking("By CPU", bucket.consumers) { usage in
                            PercentFormatter.string(usage.cpu, decimals: 1)
                        }
                        ranking("By memory", bucket.byFootprint) { usage in
                            ByteFormatter.memory(usage.footprint)
                        }
                    }

                    // Otherwise the list reads as everything that was
                    // running.
                    Text(
                        "\(min(Self.shownConsumers, bucket.consumers.count)) of each ranking, out of \(bucket.consumers.count) recorded — only the heaviest ten by CPU and by memory are kept"
                    )
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                } else {
                    // An empty bucket is an answer: asleep, switched off, or
                    // older than the history is kept for.
                    Text("No processes recorded for this bucket")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            // Fixed, and the reason the readout is drawn with no cursor at
            // all: the charts above are greedy, so a block appearing mid-scrub
            // takes its height out of them and the picture jumps under the
            // pointer. Reserved for five rows for the same reason.
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
                Button {
                    openCard(.name(usage.name))
                } label: {
                    HStack(spacing: 4) {
                        Text(usage.name)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        Text(value(usage))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Text("\u{203A}")
                            .foregroundStyle(.tertiary)
                    }
                    .font(.system(size: 11))
                    .contentShape(Rectangle())
                }
                .buttonStyle(RowButtonStyle())
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
                // Why min and max are stored: a bucket that averaged 20 % but
                // touched 100 % is not a quiet bucket.
                Text(band(presentation, sample: sample))
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .frame(width: 112, alignment: .leading)

            HistoryChart(
                runs: slice.runs(presentation.series),
                colour: presentation.colour,
                range: presentation.range,
                startsAtZero: presentation.startsAtZero,
                // Forced, so the rule lands on the same x in all five: a series
                // that stopped recording early would squeeze its own axis.
                timeDomain: slice.start...slice.end,
                showsTimeAxis: showsTimeAxis,
                yAxisValues: 3,
                // The widest label these rows can print, "28,6 MB/s" at 50
                // points, so every plot is inset the same and the five columns
                // are one.
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

    /// The inspected bucket's average, the latest stored one at rest, and an em
    /// dash where the moment has no row.
    private func reading(
        _ presentation: MetricPresentation,
        sample: HistorySample?,
        inspecting: Bool,
        slice: HistorySlice
    ) -> String {
        if let sample {
            return presentation.format(sample.aggregate.average)
        }
        // A cursor over a gap. Never the neighbouring bucket's value, which
        // would disagree with the gap the chart is drawing.
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
