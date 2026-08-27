import CaliperCore
import CaliperHistory
import SwiftUI

/// The history window: a sidebar of metrics with live values, and either one of
/// them charted over the chosen span or all of them at once.
struct DashboardView: View {
    @Environment(\.controlActiveState) private var controlActiveState
    let metrics: LiveMetrics
    let history: HistoryReader?
    /// How long the process history is kept — what says whether the moment
    /// under the cursor is still stored. The settings room reads and writes
    /// these directly.
    let preferences: Preferences
    let historyActions: HistoryActions?
    let updater: UpdaterService
    /// Owned by the window controller, so the status bar menu can open the
    /// window straight onto the settings.
    @Bindable var navigation: DashboardNavigation

    var body: some View {
        NavigationSplitView {
            List(DashboardSection.listed, id: \.self, selection: $navigation.section) { section in
                HStack {
                    Text(section.title)
                    Spacer()
                    if case .module(let module) = section {
                        Text(liveValue(for: module))
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
                .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 180, max: 220)
            // No sidebar toggle: with no toolbar to live in, SwiftUI parks it
            // in the title bar as a stray control that slides sideways when the
            // sidebar collapses.
            .toolbar(removing: .sidebarToggle)
            // Pinned under the metrics: settings are not a sixth thing to
            // monitor.
            .safeAreaInset(edge: .bottom, spacing: 0) { settingsRow }
        } detail: {
            switch navigation.section {
            case .overview:
                // Read here, not captured at build: the settings room writes
                // this very preference.
                OverviewPane(
                    metrics: metrics,
                    history: history,
                    processRetention: preferences.processRetention,
                    recordsProcesses: preferences.recordsProcessHistory
                )
            case .module(let module):
                DashboardPane(metrics: metrics, history: history, module: module)
            case .settings:
                SettingsPane(
                    preferences: preferences,
                    history: historyActions,
                    metrics: metrics,
                    updater: updater
                )
            }
        }
        .navigationTitle("Caliper")
    }

    /// Pinned rather than listed, so its selected look is drawn by hand — the
    /// same accent fill and radius the sidebar gives its own rows.
    private var settingsRow: some View {
        let isSelected = navigation.section == .settings
        // The system's selection colours, not white on the accent: yellow or
        // graphite leaves white text unreadable, and an inactive sidebar draws
        // its selection grey — this row would stay lit while the rest went
        // quiet.
        let isKey = controlActiveState != .inactive
        let fill = Color(isKey ? .selectedContentBackgroundColor : .unemphasizedSelectedContentBackgroundColor)
        let label = Color(isKey ? .alternateSelectedControlTextColor : .labelColor)

        return VStack(spacing: 0) {
            Divider()
            Button {
                navigation.section = .settings
            } label: {
                Label("Settings", systemImage: "gearshape")
                    .foregroundStyle(isSelected ? label : Color.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(isSelected ? fill : .clear)
                    )
            }
            .buttonStyle(.plain)
            // Nothing about a `Button` says which one is current.
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .padding(8)
        }
    }

    private func liveValue(for module: MenuBarModule) -> String {
        guard let snapshot = metrics.snapshot else { return "—" }
        switch module {
        case .cpu:
            return snapshot.cpu.map { PercentFormatter.string($0.total) } ?? "—"
        case .memory:
            return snapshot.memory.map { ByteFormatter.memory($0.used) } ?? "—"
        case .network:
            return snapshot.network.map { RateFormatter.panel($0.downloadRate) } ?? "—"
        case .disk:
            return snapshot.volumes?.first.map { ByteFormatter.capacity($0.availableCapacity) } ?? "—"
        case .temperature:
            return metrics.currentPeakTemperature.map { TemperatureFormatter.string($0) } ?? "—"
        }
    }
}

/// What the sidebar can select. Its own type rather than more `MenuBarModule`
/// cases: neither the overview nor the settings has an indicator to draw or a
/// panel to open, and they would have to be excluded everywhere the menu bar
/// iterates the modules.
enum DashboardSection: Hashable {
    case overview
    case module(MenuBarModule)

    case settings

    /// Settings is not in it — it is pinned under the list.
    static let listed: [DashboardSection] = [.overview] + MenuBarModule.allCases.map(DashboardSection.module)

    var title: String {
        switch self {
        case .overview: "Overview"
        case .module(let module): module.title
        case .settings: "Settings"
        }
    }
}

/// The charted pane. Internal rather than private so the preview harness can
/// render it: `ImageRenderer` refuses `NavigationSplitView`, but the pane
/// inside it — the part this app actually draws — renders fine.
struct DashboardPane: View {
    let metrics: LiveMetrics
    let history: HistoryReader?
    let module: MenuBarModule
    /// Handed in by the preview harness, which can neither wait for a query
    /// nor place a cursor.
    private let preloaded: DashboardHistory?

    @State private var span: HistorySpan = .day
    @State private var loader: DashboardHistory?
    @State private var cursor: Date?

    init(metrics: LiveMetrics, history: HistoryReader?, module: MenuBarModule) {
        self.metrics = metrics
        self.history = history
        self.module = module
        self.preloaded = nil
    }

    init(metrics: LiveMetrics, module: MenuBarModule, preloaded: DashboardHistory, cursor: Date) {
        self.metrics = metrics
        self.history = nil
        self.module = module
        self.preloaded = preloaded
        _cursor = State(initialValue: cursor)
    }

    var body: some View {
        let presentation = MetricPresentation(module: module)

        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("\(module.title) — \(span.title)")
                    .font(.system(size: 17, weight: .semibold))
                Spacer()
                SpanPicker(span: $span)
            }

            if active?.slice != nil {
                Text(captionText(presentation))
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            chart(presentation)
                .frame(minHeight: 220)
                .dashboardCard()

            HStack(spacing: 12) {
                ForEach(statistics(presentation), id: \.label) { statistic in
                    StatCard(label: statistic.label, value: statistic.value)
                }
            }

            HStack(spacing: 12) {
                ForEach(presentation.companions, id: \.self) { companion in
                    MiniChartCard(module: companion, slice: active?.slice)
                }
            }

            Spacer()
        }
        .padding(20)
        // What the content needs: 40 of padding, five 16 pt gaps, header,
        // caption, the chart's own 220 pt minimum inside a 12 pt card, a stat
        // card and a mini card. Below this the cards are squeezed instead.
        .frame(minWidth: 560, minHeight: 580, alignment: .topLeading)
        .task(id: TaskKey(module: module, span: span)) {
            let loader = loader ?? preloaded ?? DashboardHistory(reader: history)
            self.loader = loader
            // Same query as the metric itself, so the companions cannot be
            // showing a different stretch of time.
            loader.load(
                ([module] + presentation.companions).map { MetricPresentation(module: $0).series },
                span: span
            )
        }
        // A bucket of one span is not a bucket of another.
        .onChange(of: TaskKey(module: module, span: span)) { cursor = nil }
        .onReceive(NotificationCenter.default.publisher(for: .historyDidChange)) {
            _ in loader?.reload()
        }
        .onDisappear { loader?.stop() }
    }

    private struct TaskKey: Equatable {
        let module: MenuBarModule
        let span: HistorySpan
    }

    /// The loader in use. `loader` is only assigned once the view's task has
    /// run, which it never does under `ImageRenderer`; a preloaded one is
    /// already complete and can be read straight away.
    private var active: DashboardHistory? { loader ?? preloaded }

    /// The cursor, if the moment it pins is still inside the loaded range — the
    /// window keeps moving, and a moment pinned twenty minutes ago falls off the
    /// left of an hour-wide span.
    private func inspected(in slice: HistorySlice) -> Date? {
        guard let cursor, slice.cursorRange?.contains(cursor) == true else { return nil }
        return cursor
    }

    /// The line under the header, and what VoiceOver reads off the chart. The
    /// stat cards below are aggregates over the whole span; a cursor asks a
    /// different question and gets its own line rather than overwriting
    /// theirs.
    private func captionText(_ presentation: MetricPresentation) -> String {
        guard let slice = active?.slice, let moment = inspected(in: slice) else {
            return "Drag across the chart, or press the arrow keys, to read one bucket"
        }
        let bucket = bucketLabel(moment, in: slice, span: span)

        // Never the neighbouring bucket's value: the chart draws a gap there.
        guard let sample = slice.sample(presentation.series, at: moment) else {
            return "\(bucket) · —"
        }
        let aggregate = sample.aggregate
        return "\(bucket) · \(presentation.format(aggregate.average))"
            + " (\(presentation.format(aggregate.minimum))–\(presentation.format(aggregate.maximum)))"
    }

    @ViewBuilder
    private func chart(_ presentation: MetricPresentation) -> some View {
        // The *pane's own* series, not the loader's state: the query asks for
        // the companions too, and a slice counts as loaded when any series in it
        // has rows — so a Mac with no readable sensors would draw an empty
        // temperature chart with axes instead of saying so.
        if case .loaded(let slice) = active?.state, !slice[presentation.series].isEmpty {
            HistoryChart(
                runs: slice.runs(presentation.series),
                colour: presentation.colour,
                range: presentation.range,
                startsAtZero: presentation.startsAtZero,
                cursor: inspected(in: slice),
                onScrub: { moment in
                    cursor = moment.map { slice.bucket(containing: $0) }
                },
                axisLabel: presentation.format
            )
            .chartCursorKeys($cursor, in: slice)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(module.title) over the \(span.title)")
        } else {
            HistoryPlaceholder(state: emptyState)
        }
    }

    /// A loaded slice with nothing for this metric is "no history yet" rather
    /// than the "cannot read the store" the loader's state still reports.
    private var emptyState: DashboardHistory.State? {
        guard case .loaded = active?.state else { return active?.state }
        return .empty
    }

    /// Over the *stored* span, which is what the chart shows — not the live
    /// buffer.
    private func statistics(_ presentation: MetricPresentation) -> [(label: String, value: String)] {
        guard let samples = active?.slice?[presentation.series], !samples.isEmpty else { return [] }
        let averages = samples.map(\.aggregate.average)
        return [
            ("Average", presentation.format(averages.reduce(0, +) / Double(averages.count))),
            ("Peak", presentation.format(samples.map(\.aggregate.maximum).max() ?? 0)),
            ("Low", presentation.format(samples.map(\.aggregate.minimum).min() ?? 0)),
        ]
    }
}

/// The range picker, shared by both panes so they cannot drift apart.
struct SpanPicker: View {
    @Binding var span: HistorySpan

    var body: some View {
        Picker("", selection: $span) {
            ForEach(HistorySpan.allCases) { option in
                Text(option.label).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .font(.system(size: 13))
    }
}

/// "Cannot read the data" and "no data yet" call for different reactions, so
/// they do not share a message.
struct HistoryPlaceholder: View {
    let state: DashboardHistory.State?

    var body: some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var title: String {
        switch state {
        case .unavailable: "History unavailable"
        case .empty: "No history yet"
        default: "Loading…"
        }
    }

    private var detail: String {
        switch state {
        case .unavailable: "The history store could not be opened."
        case .empty: "Caliper records from launch; this span fills in as it runs."
        default: ""
        }
    }
}

/// Everything that differs between metrics, decided once: which series is
/// charted, its scale and how its numbers are written vary together, and
/// parallel switches would have to be kept in step.
@MainActor
struct MetricPresentation {
    let series: MetricSeries
    let colour: Color
    let range: ClosedRange<Double>?
    /// Rates and fractions are measured from zero; temperature is not.
    let startsAtZero: Bool
    let format: (Double) -> String
    /// The two neighbours that most often explain this metric, drawn small
    /// underneath it — a chart of one metric rarely answers *why*. Each card
    /// carries the neighbour's sidebar title, so it doubles as a pointer.
    ///
    /// CPU is in all four of the others: it explains most of what the machine
    /// does.
    let companions: [MenuBarModule]

    init(module: MenuBarModule) {
        switch module {
        case .cpu:
            series = .cpu
            colour = Color(Palette.cpu)
            startsAtZero = true
            range = 0...1
            format = { PercentFormatter.string($0) }
            // Load is explained by what it was working on, and the die follows
            // it a few buckets later.
            companions = [.memory, .temperature]
        case .memory:
            series = .memory
            colour = Color(Palette.memory)
            startsAtZero = true
            range = 0...1
            format = { PercentFormatter.string($0) }
            // Pressure shows up as swap, and swap is disk writes.
            companions = [.cpu, .disk]
        case .temperature:
            series = .temperature
            colour = Color(Palette.temperature)
            startsAtZero = false
            range = nil
            format = { TemperatureFormatter.string($0) }
            // The two things in this app that make heat.
            companions = [.cpu, .disk]
        // The full rate form, not the menu bar's compact one: "11,7 M" leaves
        // both the unit and the per-second to be guessed at.
        case .network:
            series = .networkDownload
            colour = Color(Palette.networkDown)
            startsAtZero = true
            range = nil
            format = { RateFormatter.panel($0) }
            // What the traffic was for, and where it ended up.
            companions = [.cpu, .disk]
        case .disk:
            series = .diskRead
            colour = Color(Palette.disk)
            startsAtZero = true
            range = nil
            format = { RateFormatter.panel($0) }
            // A busy disk is a build or a download landing on it.
            companions = [.cpu, .network]
        }
    }
}

/// The surface every block on the dashboard sits on, written once so the
/// chart, the stat cards and the mini charts cannot drift apart.
extension View {
    func dashboardCard() -> some View {
        padding(12)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// One companion metric: its name, last reading, and shape over the same
/// span.
private struct MiniChartCard: View {
    let module: MenuBarModule
    let slice: HistorySlice?

    var body: some View {
        let presentation = MetricPresentation(module: module)
        let samples = slice?[presentation.series] ?? []

        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(module.title)
                    .font(.system(size: 12, weight: .medium))
                Spacer()
                Text(reading(presentation, samples: samples))
                    .font(.system(size: 12))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }

            MiniChart(
                runs: slice?.runs(presentation.series) ?? [],
                colour: presentation.colour,
                range: presentation.range,
                startsAtZero: presentation.startsAtZero
            )
            .frame(height: 64)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 12))
    }

    /// The latest stored bucket, not the live value: the sidebar's live reading
    /// is a different quantity for two modules — memory as bytes used, disk as
    /// free capacity — so the card's figure and its chart would disagree. Out of
    /// the same samples the line is drawn from, so it is "now" to within a
    /// bucket.
    private func reading(_ presentation: MetricPresentation, samples: [HistorySample]) -> String {
        guard let latest = samples.last else { return "—" }
        return presentation.format(latest.aggregate.average)
    }
}

private struct StatCard: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.5)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 22))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard()
    }
}
