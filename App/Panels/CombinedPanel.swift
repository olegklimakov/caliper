import Foundation
import SwiftUI

/// Every module at a glance, behind the one combined menu bar item.
///
/// One window with two levels rather than five popovers: the list answers "how
/// is the machine", and a row opens the module's own panel in place — the same
/// panel its own status item would have opened, with its title turned into the
/// way back.
struct CombinedPanel: View {
    let metrics: LiveMetrics
    /// Read live rather than captured: the settings screen can be open beside
    /// this, and a module switched on there should appear here.
    let preferences: Preferences
    let openHistory: () -> Void
    let openSettings: () -> Void

    /// Which module the window has been drilled into, if any. State rather than
    /// a second popover: the window the user opened is the window they keep.
    @State private var opened: MenuBarModule?

    var body: some View {
        if let opened {
            PanelFactory.view(
                for: opened,
                metrics: metrics,
                openHistory: openHistory,
                onBack: { self.opened = nil }
            )
        } else {
            summary
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, PanelMetrics.padding)
                .padding(.top, 14)
                .padding(.bottom, 12)

            ForEach(preferences.menuBar.enabled, id: \.self) { module in
                Divider()
                Button {
                    opened = module
                } label: {
                    CombinedRow(module: module, metrics: metrics)
                }
                .buttonStyle(RowButtonStyle())
            }

            Divider()
            footer
                .padding(.horizontal, PanelMetrics.padding)
                .padding(.top, 11)
                .padding(.bottom, 13)
        }
        .frame(width: PanelMetrics.width)
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                SectionLabel("System")
                Text(metrics.snapshot?.host.chip ?? "Caliper")
                    .font(.system(size: 14, weight: .semibold))
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 3) {
                headerFigure("Uptime", Self.uptime)
                if let load = metrics.snapshot?.cpu?.loadAverage {
                    headerFigure("Load", Decimals.string("%.2f", load.oneMinute))
                }
            }
        }
    }

    private func headerFigure(_ label: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Text(value)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack {
            Button(action: openSettings) {
                Text("Settings…")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            Spacer()
            Button(action: openHistory) {
                Text("History \u{203A}")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }

    /// Since boot, from the process's own clock rather than a sampler: nothing
    /// polls it, and it is the one number here that changes by the second and
    /// matters by the day.
    private static var uptime: String {
        let seconds = Int(ProcessInfo.processInfo.systemUptime)
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        if days > 0 { return "\(days) d \(hours) h" }
        return "\(hours) h \((seconds % 3_600) / 60) m"
    }
}

/// One module's line: what it reads, and the shape of how it has been reading.
private struct CombinedRow: View {
    let module: MenuBarModule
    let metrics: LiveMetrics

    var body: some View {
        let reading = ModuleReading(module, metrics: metrics)
        HStack(spacing: 8) {
            SectionLabel(module.title)
                // Wide enough for "NETWORK" on one line: the longest label
                // decides the column, and a wrapped one makes its row taller
                // than every other.
                .lineLimit(1)
                .frame(width: 66, alignment: .leading)
            Text(reading.value)
                .font(.system(size: 15, weight: .medium))
                .monospacedDigit()
                .layoutPriority(1)
            Text(reading.note)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            glance
                .frame(width: 56, height: 20)
            // A text chevron rather than an SF Symbol, the way the footer's
            // History affordance is drawn: it inherits the label's metrics.
            Text("\u{203A}")
                .font(.system(size: 13))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, PanelMetrics.padding)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    /// The module's own language, shrunk: whatever its panel draws large, this
    /// draws in fifty-six points.
    @ViewBuilder
    private var glance: some View {
        switch module {
        case .cpu:
            LiveChart(
                series: [.init(id: "cpu", values: Array(metrics.cpuTotal), colour: Color(Palette.cpu))],
                range: 0...1
            )
        case .memory:
            ProportionBar(fraction: metrics.snapshot?.memory?.usedFraction ?? 0, colour: Color(Palette.memory))
                .frame(height: 6)
        case .network:
            MirroredChart(download: Array(metrics.download), upload: Array(metrics.upload))
        case .disk:
            ProportionBar(fraction: usedCapacity, colour: Color(Palette.disk))
                .frame(height: 6)
        case .temperature:
            LiveChart(
                series: [
                    .init(
                        id: "temperature",
                        values: Array(metrics.peakTemperature),
                        colour: Color(Palette.temperature)
                    )
                ],
                range: nil
            )
        }
    }

    private var usedCapacity: Double {
        guard let volume = metrics.snapshot?.volumes?.first, volume.totalCapacity > 0 else { return 0 }
        return 1 - Double(volume.availableCapacity) / Double(volume.totalCapacity)
    }
}

/// A row that highlights under the pointer, the way a menu item does, and
/// nowhere else takes the plain button's centring or its blue.
private struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    /// A view of its own rather than `configuration.label` decorated in place.
    /// SwiftUI installs `@State` storage on views; a `ButtonStyle` is not one,
    /// so state held there is rebuilt on every render and `onHover` writes into
    /// nothing — the highlight simply never appears.
    private struct Row: View {
        let configuration: Configuration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .foregroundStyle(.primary)
                .background(
                    isHovered || configuration.isPressed
                        ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.clear)
                )
                .onHover { isHovered = $0 }
        }
    }
}
