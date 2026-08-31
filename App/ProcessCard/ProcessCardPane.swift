import CaliperCore
import CaliperHistory
import SwiftUI

/// Owns one card's model for exactly as long as the room is on screen: the
/// probe starts on appear and stops on disappear, which is what bounds its
/// cost to "a card is open".
struct ProcessCardRoom: View {
    let target: ProcessCardTarget
    let reader: HistoryReader?
    let onBack: () -> Void

    @State private var model: ProcessCardModel

    init(target: ProcessCardTarget, reader: HistoryReader?, onBack: @escaping () -> Void) {
        self.target = target
        self.reader = reader
        self.onBack = onBack
        _model = State(initialValue: ProcessCardModel(target: target, reader: reader))
    }

    var body: some View {
        ProcessCardPane(model: model, onBack: onBack)
            .onAppear { model.start() }
            .onDisappear { model.stop() }
    }
}

/// One process's room in the history window — the app, not the pid.
struct ProcessCardPane: View {
    @Bindable var model: ProcessCardModel
    let onBack: () -> Void

    @State private var confirming: Termination?

    enum Termination: Identifiable {
        case quit
        case force

        var id: Bool { self == .force }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            switch model.presence {
            case .warming:
                Spacer()
                HStack {
                    Spacer()
                    ProgressView()
                    Spacer()
                }
                Spacer()
            case .live:
                if let reading = model.reading {
                    statRows(reading)
                    familyCard(reading)
                }
                historyCard
                Spacer(minLength: 0)
            case .exited:
                historyCard
                Spacer(minLength: 0)
            }
        }
        .padding(20)
        .frame(minWidth: 560, minHeight: 560)
        .confirmationDialog(
            confirming == .force ? "Force Quit \(model.displayName)?" : "Quit \(model.displayName)?",
            isPresented: Binding(
                get: { confirming != nil },
                set: { if !$0 { confirming = nil } }
            ),
            titleVisibility: .visible,
            presenting: confirming
        ) { termination in
            Button(
                termination == .force ? "Force Quit" : "Quit",
                role: .destructive
            ) {
                model.terminate(force: termination == .force)
            }
            Button("Cancel", role: .cancel) {}
        } message: { termination in
            Text(
                termination == .force
                    ? "The process is killed without a chance to save. Unsaved data is lost."
                    : "The process is asked to quit and may save first."
            )
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Button(action: onBack) {
                // The chevron the rows point with, turned around — the same
                // affordance the combined panel's drilled state uses.
                Text("\u{2039}")
                    .font(.system(size: 17, weight: .medium))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            iconView

            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName)
                    .font(.system(size: 17, weight: .semibold))
                HStack(spacing: 4) {
                    if let identifier = model.family.bundleIdentifier {
                        Text(identifier)
                    }
                    if case .live = model.presence, let reading = model.reading {
                        Text("· \(reading.members.count) \(reading.members.count == 1 ? "process" : "processes")")
                            .monospacedDigit()
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            switch model.presence {
            case .live:
                if let root = model.reading?.members.first(where: \.isRoot) {
                    Text("running \(DurationFormatter.brief(root.runningFor))")
                        .font(.system(size: 11))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                if !model.quitTargets.isEmpty {
                    Button("Quit…") { confirming = .quit }
                    Button("Force Quit…") { confirming = .force }
                }
            case .exited(let lastSeen):
                Text("Exited · last seen \(lastSeen.formatted(date: .omitted, time: .shortened))")
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 5))
            case .warming:
                EmptyView()
            }
        }
    }

    @ViewBuilder
    private var iconView: some View {
        if let icon = model.icon {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 32, height: 32)
                .saturation(model.presence == .live ? 1 : 0)
                .opacity(model.presence == .live ? 1 : 0.7)
        } else {
            RoundedRectangle(cornerRadius: 7)
                .fill(.quaternary)
                .frame(width: 32, height: 32)
                .overlay {
                    Image(systemName: "gearshape.2")
                        .foregroundStyle(.secondary)
                }
        }
    }

    // MARK: - Live stats

    private func statRows(_ reading: ProcessCardReading) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                CardStat(label: "CPU", value: PercentFormatter.string(reading.cpu, decimals: 1)) {
                    if let share = reading.performanceCycleShare {
                        Text("\(PercentFormatter.string(share)) P-cores")
                            .font(.system(size: 10))
                            .monospacedDigit()
                            .foregroundStyle(Color(Palette.cpu))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 4))
                    }
                }
                CardStat(label: "Power", value: PowerFormatter.string(reading.power))
                if reading.gpuIsAvailable {
                    CardStat(label: "GPU time", value: DurationFormatter.clock(reading.gpuTime))
                }
                CardStat(label: "Wakeups", value: Decimals.string("%.0f /s", reading.wakeupsPerSecond))
            }
            HStack(alignment: .top, spacing: 12) {
                memoryStat(reading)
                CardStat(
                    label: "Disk",
                    value: "↓ \(RateFormatter.panel(reading.readRate))",
                    valueSize: 16
                ) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("↑ \(RateFormatter.panel(reading.writeRate))")
                            .font(.system(size: 16))
                            .monospacedDigit()
                        Text("read · written")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
                qosStat(reading)
            }
        }
    }

    private func memoryStat(_ reading: ProcessCardReading) -> some View {
        // No proportion bar here: the family total has no lifetime maximum to
        // stand against — summing the members' peaks would claim a moment
        // that never happened. The largest single member's peak is a true
        // fact, so it is said in words instead.
        let peak = reading.members.map(\.lifetimeMaxFootprint).max() ?? 0
        return CardStat(label: "Memory", value: ByteFormatter.memory(reading.footprint)) {
            if peak > 0 {
                Text("largest member ever \(ByteFormatter.memory(peak))")
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func qosStat(_ reading: ProcessCardReading) -> some View {
        // "—" for no data *and* for an idle interval: a nonzero lifetime with
        // zero deltas leaves nothing to apportion either.
        CardStat(label: "QoS time", value: qosSlices(reading.qos)?.isEmpty == false ? "" : "—") {
            if let slices = qosSlices(reading.qos), !slices.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    GeometryReader { geometry in
                        HStack(spacing: 0) {
                            ForEach(slices) { slice in
                                Rectangle()
                                    .fill(slice.colour)
                                    .frame(width: geometry.size.width * slice.fraction)
                            }
                        }
                    }
                    .frame(height: 6)
                    .clipShape(RoundedRectangle(cornerRadius: 3))
                    HStack(spacing: 10) {
                        ForEach(slices) { slice in
                            HStack(spacing: 3) {
                                Circle().fill(slice.colour).frame(width: 5, height: 5)
                                Text(slice.name)
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private struct QoSSlice: Identifiable {
        let name: String
        let fraction: Double
        let colour: Color

        var id: String { name }
    }

    /// Four segments from seven tiers — which side `utility` or `legacy`
    /// falls on is presentation policy, and this is where policy lives.
    private func qosSlices(_ qos: QoSBreakdown?) -> [QoSSlice]? {
        guard let qos else { return nil }
        let grouped: [(String, Double, NSColor)] = [
            ("interactive", qos.userInteractive + qos.userInitiated, Palette.cpu),
            ("default", qos.defaultTier + qos.legacy, .systemGray),
            ("utility", qos.utility, Palette.warning),
            ("background", qos.background + qos.maintenance, Palette.cpuEfficiency),
        ]
        let total = grouped.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return [] }
        return grouped.compactMap { name, value, colour in
            value > 0 ? QoSSlice(name: name, fraction: value / total, colour: Color(colour)) : nil
        }
    }

    // MARK: - Family

    private func familyCard(_ reading: ProcessCardReading) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel("Processes · \(min(reading.members.count, 6)) of \(reading.members.count) shown")
            familyRow(
                name: "\(model.displayName) — total",
                pid: nil,
                cpu: reading.cpu,
                footprint: reading.footprint,
                emphasized: true
            )
            Divider()
            ForEach(reading.members.prefix(6), id: \.pid) { member in
                familyRow(
                    name: member.name,
                    pid: member.pid,
                    cpu: member.cpu,
                    footprint: member.footprint,
                    emphasized: false
                )
            }
            Text("Processes of other users are not visible.")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .dashboardCard()
    }

    private func familyRow(
        name: String,
        pid: pid_t?,
        cpu: Double,
        footprint: UInt64,
        emphasized: Bool
    ) -> some View {
        HStack(spacing: 8) {
            Text(name)
                .font(.system(size: 12, weight: emphasized ? .semibold : .regular))
                .lineLimit(1)
                .truncationMode(.middle)
            if let pid {
                Text(String(pid))
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            Text(PercentFormatter.string(cpu, decimals: 1))
                .foregroundStyle(emphasized ? .primary : .secondary)
            Text(ByteFormatter.memory(footprint))
                .foregroundStyle(emphasized ? .primary : .secondary)
                .frame(width: 76, alignment: .trailing)
        }
        .font(.system(size: 12))
        .monospacedDigit()
    }

    // MARK: - History

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel("History · CPU · \(model.target.name)")
                Spacer()
                // Not a segmented `Picker`: `ImageRenderer` draws those as a
                // placeholder, which would leave the card's only control
                // unverifiable by the preview harness — the dashboard's range
                // picker already has that blind spot.
                HStack(spacing: 0) {
                    spanButton("1 H", span: 3600)
                    spanButton("24 H", span: 24 * 3600)
                }
                .padding(2)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
            if let history = model.history, !history.points.isEmpty {
                HistoryStrip(history: history, end: model.historyEnd, span: model.span)
                    .frame(height: 56)
                Text("Bars where \(model.target.name) ranked in the stored top ten — a gap means unranked, not idle.")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            } else {
                Text("No recorded buckets in this span.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 56)
            }
        }
        .dashboardCard()
    }

    private func spanButton(_ title: String, span: TimeInterval) -> some View {
        Button {
            model.span = span
        } label: {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(model.span == span ? Color.white : Color.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .background(
                    model.span == span ? Color.accentColor : .clear,
                    in: RoundedRectangle(cornerRadius: 5)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Bars per stored bucket with real holes. A `Canvas`, not chart marks: a day
/// at the minute tier is 1 440 bars, which Swift Charts redraws too slowly to
/// sit beside a live grid.
private struct HistoryStrip: View {
    let history: ProcessNameHistory
    let end: Date
    let span: TimeInterval

    var body: some View {
        Canvas { context, size in
            let tier = TimeInterval(history.tier.seconds)
            let slots = max(1, Int(span / tier))
            let start = end.addingTimeInterval(-Double(slots) * tier)
            let peak = history.points.map(\.cpu).max() ?? 0
            guard peak > 0 else { return }

            let slotWidth = size.width / CGFloat(slots)
            let barWidth = max(0.5, slotWidth - min(1, slotWidth * 0.2))
            for point in history.points {
                let index = Int(point.bucketStart.timeIntervalSince(start) / tier)
                guard (0..<slots).contains(index) else { continue }
                let height = max(1, size.height * CGFloat(point.cpu / peak))
                let bar = CGRect(
                    x: CGFloat(index) * slotWidth,
                    y: size.height - height,
                    width: barWidth,
                    height: height
                )
                context.fill(
                    Path(roundedRect: bar, cornerRadius: min(1, barWidth / 2)),
                    with: .color(Color(Palette.cpu))
                )
            }
        }
    }
}

/// Label over value, the dashboard's stat card widened to carry an extra line
/// — a chip, a bar, a legend.
private struct CardStat<Extra: View>: View {
    let label: String
    let value: String
    var valueSize: CGFloat = 20
    @ViewBuilder var extra: Extra

    init(
        label: String,
        value: String,
        valueSize: CGFloat = 20,
        @ViewBuilder extra: () -> Extra = { EmptyView() }
    ) {
        self.label = label
        self.value = value
        self.valueSize = valueSize
        self.extra = extra()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .kerning(0.5)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if !value.isEmpty {
                    Text(value)
                        .font(.system(size: valueSize))
                        .monospacedDigit()
                }
                extra
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .dashboardCard()
    }
}
