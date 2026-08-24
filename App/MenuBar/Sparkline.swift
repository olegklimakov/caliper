import AppKit
import CaliperCore

/// Draws the little line charts the menu bar indicators are built from.
enum Sparkline {
    /// Strokes `values` across `rect`, scaled to `range`.
    ///
    /// A fixed range is deliberate for percentages: auto-scaling makes an idle
    /// machine's noise look like a workload.
    static func stroke(
        values: some RandomAccessCollection<Double>,
        in rect: CGRect,
        colour: NSColor,
        lineWidth: CGFloat,
        range: ClosedRange<Double> = 0...1
    ) {
        // Five minutes of samples into twenty-eight points of width is ten
        // samples per pixel: nine tenths of the path is invisible, and stroking
        // it was a measurable share of the app's whole CPU budget.
        let values = Downsample.peaks(of: values, to: Int(rect.width))
        guard values.count > 1 else { return }

        let path = NSBezierPath()
        path.lineWidth = lineWidth
        path.lineJoinStyle = .round
        path.lineCapStyle = .round

        for (index, value) in values.enumerated() {
            let point = CGPoint(
                x: rect.minX + rect.width * CGFloat(index) / CGFloat(values.count - 1),
                y: rect.minY + rect.height * CGFloat(fraction(of: value, in: range))
            )
            if index == 0 {
                path.move(to: point)
            } else {
                path.line(to: point)
            }
        }

        colour.setStroke()
        path.stroke()
    }

    /// Fills bars across `rect`, one per value — what the network indicator and
    /// the per-core strip use, where each sample is its own thing rather than a
    /// point on a continuous line.
    static func fillBars(
        values: some RandomAccessCollection<Double>,
        in rect: CGRect,
        colour: NSColor,
        range: ClosedRange<Double> = 0...1,
        spacing: CGFloat = 1,
        growsDownward: Bool = false
    ) {
        guard !values.isEmpty else { return }

        // A bar needs a point of its own and a point of gap. Downsampled rather
        // than truncated, so every module in the strip covers the same span of
        // time — showing the last ten seconds beside a five-minute line would
        // invite comparing them.
        let visible = Downsample.peaks(of: values, to: max(1, Int(rect.width / (1 + spacing))))
        let slot = rect.width / CGFloat(visible.count)
        let barWidth = max(1, slot - spacing)
        colour.setFill()

        for (index, value) in visible.enumerated() {
            let height = max(1, rect.height * CGFloat(fraction(of: value, in: range)))
            CGRect(
                x: rect.minX + slot * CGFloat(index),
                // Mirrored charts grow away from a shared baseline, so the
                // downward half hangs from the top of its own rect.
                y: growsDownward ? rect.maxY - height : rect.minY,
                width: barWidth,
                height: height
            ).fill()
        }
    }

    private static func fraction(of value: Double, in range: ClosedRange<Double>) -> Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return min(1, max(0, (value - range.lowerBound) / span))
    }
}

extension String {
    /// Right-aligned so a value that loses a digit does not shift its label.
    ///
    /// Drawing only ever happens on the main actor — this is called from an
    /// `NSImage` drawing handler on the status item — so the attribute cache is
    /// isolated to it rather than locked.
    @MainActor
    func drawRightAligned(in rect: CGRect, font: NSFont, colour: NSColor) {
        let attributes = TextAttributes.shared.attributes(font: font, colour: colour)
        let size = (self as NSString).size(withAttributes: attributes)
        (self as NSString).draw(
            at: CGPoint(
                x: rect.maxX - size.width,
                y: rect.midY - size.height / 2
            ),
            withAttributes: attributes
        )
    }
}

/// Reuses the attribute dictionaries the indicators draw with.
///
/// There are four of them across the whole strip, and building one per draw
/// call meant allocating a dictionary several times a second for the life of
/// the app — the menu bar redraws whenever a value changes, which for a
/// sparkline is every tick.
@MainActor
final class TextAttributes {
    static let shared = TextAttributes()

    private var cache: [Key: [NSAttributedString.Key: Any]] = [:]

    private struct Key: Hashable {
        let font: NSFont
        let colour: NSColor
    }

    func attributes(font: NSFont, colour: NSColor) -> [NSAttributedString.Key: Any] {
        let key = Key(font: font, colour: colour)
        if let cached = cache[key] {
            return cached
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: colour]
        cache[key] = attributes
        return attributes
    }
}
