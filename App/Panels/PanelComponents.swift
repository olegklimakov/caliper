import SwiftUI

/// The pieces every panel is built from, matching the components in
/// `Caliper.pen`: panel header, section label, metric row, chip.
///
/// Colours here are semantic (`.primary`, `.secondary`) rather than the painted
/// fills of the mockup. The panel sits on the system's `.popover` material, and
/// semantic colours are what keep it legible through vibrancy and under
/// Increase Contrast and Reduce Transparency.
enum PanelMetrics {
    static let width: CGFloat = 320
    static let padding: CGFloat = 16
    static let sectionGap: CGFloat = 12
    static let cardRadius: CGFloat = 8
    static let chartHeight: CGFloat = 72
}

/// Title, big value, and up to two chips — the top of every panel.
struct PanelHeader: View {
    /// Set only when the panel was opened from the combined window, where the
    /// title is also the way back. Nothing else in the app has a level above a
    /// panel to return to.
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
                        // Brighter than the label it replaces: this one can be
                        // clicked, and the accent colour is not an option over
                        // a translucent popover.
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
    /// Wide enough for the longest value any panel prints. That is "1 022,3 MB"
    /// at 72 points — measured in this Mac's locale, where a thousands
    /// separator and a decimal comma both take room the bare "1022.3 MB" does
    /// not, and where getting it wrong truncates the number to "1 013,4…".
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
                // Fixed exactly when there is a bar to keep in line: a column
                // that grows with its own text puts "637 MB" and "637,4 MB" at
                // different widths, and every bar in the list then starts at a
                // different place. Rows without a bar keep their natural width,
                // because an IP address does not fit in a value column.
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

    /// A minimum of two points so that a small value is still visible as a
    /// value — but nothing at all at zero, or a stopped fan reads as turning
    /// slowly next to the word "Off".
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
            // Charts draw outside the frame they were given. An `AreaMark`'s
            // gradient runs past the bottom of the plot and kept going: measured
            // on the sensors panel, the fill was still visible eighteen points
            // below the card it is supposed to sit inside, fading out over the
            // rows beneath it. It reads as a rendering fault, because it is one.
            .clipped()
            .padding(6)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: PanelMetrics.cardRadius))
    }
}

/// Tertiary detail on the left, the shared History affordance on the right.
///
/// Every panel carries the same affordance in the same place, so "where is the
/// history" has one answer rather than five.
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
                // A text chevron rather than an SF Symbol: it inherits the
                // label's metrics, so the affordance never shifts by a point
                // when the font size changes.
                Text("History \u{203A}")
                    .font(.system(size: 11, weight: .medium))
                    // Semantic rather than the accent colour, over a fill of
                    // its own. A popover is translucent, and the accent is a
                    // fixed colour that cannot know what is behind it: with a
                    // blue window under the panel, blue-on-blue left nothing
                    // to see. The hierarchical styles are vibrant — the
                    // material blends them against whatever is actually there.
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())
            }
            .buttonStyle(.plain)
        }
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
