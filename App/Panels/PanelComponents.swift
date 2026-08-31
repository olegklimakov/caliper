import CaliperCore
import SwiftUI

/// The pieces every panel is built from, matching the components in
/// `Caliper.pen`.
///
/// Colours are semantic rather than the mockup's painted fills: the panel sits
/// on the `.popover` material, and only semantic colours stay legible through
/// vibrancy and under Increase Contrast and Reduce Transparency.
enum PanelMetrics {
    static let width: CGFloat = 320
    static let padding: CGFloat = 16
    static let sectionGap: CGFloat = 12
    static let cardRadius: CGFloat = 8
    static let chartHeight: CGFloat = 72
}

/// Title, big value, and up to two chips — the top of every panel.
struct PanelHeader: View {
    /// Set only from the combined window, where the title is also the way back
    /// — nothing else has a level above a panel.
    var onBack: (() -> Void)?
    let title: String
    let value: String
    let unit: String
    var chips: [PanelChip.Model] = []

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                if let onBack {
                    Button(action: onBack) {
                        HStack(spacing: 3) {
                            // The chevron the rows point with, turned around.
                            Text("\u{2039}")
                                .font(.system(size: 13, weight: .medium))
                            SectionLabel(title)
                        }
                        // Brighter than the label it replaces, because this one
                        // can be clicked. Not the accent: see the footer.
                        .foregroundStyle(.primary)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                } else {
                    SectionLabel(title)
                }
                HStack(alignment: .firstTextBaseline, spacing: 2) {
                    Text(value)
                        .font(.system(size: 30, weight: .regular, design: .default))
                        .monospacedDigit()
                    Text(unit)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                ForEach(chips) { chip in
                    PanelChip(model: chip)
                }
            }
        }
    }
}

/// Uppercase 11 pt label that opens each section.
struct SectionLabel: View {
    private let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .kerning(0.5)
            .foregroundStyle(.secondary)
    }
}

/// A dot, a name and a value — how a panel names the parts of its total.
struct PanelChip: View {
    struct Model: Identifiable {
        let id = UUID()
        let colour: Color
        let label: String
        let value: String
    }

    let model: Model

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(model.colour)
                .frame(width: 6, height: 6)
            Text(model.label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(model.value)
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
        }
    }
}

/// Name on the left, a proportion bar, and the value on the right. The bar is
/// what makes a list of numbers comparable at a glance.
struct MetricRow: View {
    let name: String
    let value: String
    /// 0…1 of the row's bar, or `nil` for rows that are not a proportion.
    var fraction: Double?
    var colour: Color = .accentColor
    var barWidth: CGFloat = 68
    /// The longest value any panel prints: "1 022,3 MB" at 72 points, measured
    /// in a locale with a thousands separator and a decimal comma. Too narrow
    /// truncates the number to "1 013,4…".
    var valueWidth: CGFloat = 74

    var body: some View {
        HStack(spacing: 8) {
            Text(name)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 4)
            if let fraction {
                ProportionBar(fraction: fraction, colour: colour)
                    .frame(width: barWidth, height: 4)
            }
            Text(value)
                .font(.system(size: 13))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                // Fixed only where there is a bar to keep in line: "637 MB" and
                // "637,4 MB" at different widths start every bar in a different
                // place. Rows without one keep their natural width, because an
                // IP address does not fit a value column.
                .frame(width: fraction == nil ? nil : valueWidth, alignment: .trailing)
        }
    }
}

struct ProportionBar: View {
    let fraction: Double
    let colour: Color

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(colour)
                    .frame(width: width(in: geometry.size.width))
            }
        }
    }

    /// Two points minimum so a small value is still visible — but nothing at
    /// zero, or a stopped fan reads as turning slowly beside the word "Off".
    private func width(in available: CGFloat) -> CGFloat {
        guard fraction > 0 else { return 0 }
        return max(2, available * min(1, fraction))
    }
}

/// The inset card the charts sit in.
struct ChartCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .frame(height: PanelMetrics.chartHeight)
            .frame(maxWidth: .infinity)
            .padding(6)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: PanelMetrics.cardRadius))
    }
}

/// Tertiary detail on the left, the History affordance on the right. Every
/// panel carries it in the same place, so "where is the history" has one
/// answer.
struct PanelFooter: View {
    let detail: String
    /// Dismisses the popover; opening the window is this view's own business.
    let openHistory: () -> Void

    var body: some View {
        HStack {
            Text(detail)
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
            Spacer()
            Button(action: openHistory) {
                // Text rather than an SF Symbol: it inherits the label's
                // metrics, so it never shifts when the font size changes.
                Text("History \u{203A}")
                    .font(.system(size: 11, weight: .medium))
                    // Semantic, not the accent: a popover is translucent and
                    // the accent cannot know what is behind it — over a blue
                    // window, blue-on-blue leaves nothing to see. Hierarchical
                    // styles are vibrant and blend against what is there.
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }
            .buttonStyle(.plain)
        }
    }
}

/// A row that highlights under the pointer, the way a menu item does, and
/// nowhere else takes the plain button's centring or its blue.
struct RowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Row(configuration: configuration)
    }

    /// A view of its own rather than `configuration.label` decorated in place:
    /// SwiftUI installs `@State` storage on views and a `ButtonStyle` is not
    /// one, so `onHover` writes into storage rebuilt on every render.
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

/// A top-list row that opens a process card: the metric row, the chevron the
/// combined rows point with, and the hover highlight.
struct ProcessRowButton: View {
    let process: ProcessSample
    let value: String
    let fraction: Double?
    let colour: Color
    let openCard: (ProcessCardTarget) -> Void

    var body: some View {
        Button {
            openCard(.pid(process.pid, name: process.name))
        } label: {
            HStack(spacing: 4) {
                MetricRow(name: process.name, value: value, fraction: fraction, colour: colour)
                Text("\u{203A}")
                    .font(.system(size: 13))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(RowButtonStyle())
    }
}

/// The frame every panel shares: fixed width, consistent padding, sections
/// separated by dividers rather than by painted cards.
struct PanelContainer<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: PanelMetrics.sectionGap) {
            content
        }
        .padding(PanelMetrics.padding)
        .frame(width: PanelMetrics.width)
    }
}
