import CaliperCore
import SwiftUI

struct MemoryPanel: View {
    let metrics: LiveMetrics
    let openHistory: () -> Void
    /// Non-nil when this panel is a room of the combined window.
    var onBack: (() -> Void)?

    private var memory: MemorySample? { metrics.snapshot?.memory }

    var body: some View {
        PanelContainer {
            PanelHeader(
                onBack: onBack,
                title: "Memory",
                value: memory.map { ByteFormatter.memory($0.used) } ?? "—",
                unit: memory == nil ? "" : "used",
                chips: pressureChip
            )

            if let memory {
                CompositionBar(memory: memory)
                CompositionLegend(memory: memory)
                StatsRow(memory: memory)
            }

            ChartCard {
                LiveChart(
                    series: [
                        .init(
                            id: "memory",
                            values: Array(metrics.memoryUsed),
                            colour: Color(Palette.memory)
                        )
                    ],
                    range: 0...1,
                    filled: true
                )
            }

            if let processes = metrics.snapshot?.processes?.topByMemory, !processes.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Top consumers")
                    ForEach(processes.prefix(5), id: \.pid) { process in
                        MetricRow(
                            name: process.name,
                            value: ByteFormatter.memory(process.memoryFootprint),
                            fraction: fraction(of: process.memoryFootprint, in: processes),
                            colour: Color(Palette.memory)
                        )
                    }
                }
            }

            Divider()
            PanelFooter(detail: cachedDetail, openHistory: openHistory)
        }
    }

    /// The kernel's own pressure level, which is the honest answer to "is this
    /// a problem" — a Mac sits near 90 % used and is perfectly happy.
    private var pressureChip: [PanelChip.Model] {
        guard let pressure = memory?.pressure else { return [] }
        let colour: NSColor =
            switch pressure {
            case .normal: Palette.ok
            case .warning: Palette.warning
            case .critical: Palette.critical
            }
        return [
            PanelChip.Model(
                colour: Color(colour),
                label: "Pressure",
                value: pressure.rawValue.capitalized
            )
        ]
    }

    /// Against the largest consumer in the list, not against installed memory:
    /// on a 48 GB Mac even a heavy app is two per cent of the total, so every
    /// bar would be the same stub. The question this list answers is which of
    /// these five is the heavy one, and the value beside it stays absolute.
    private func fraction(of footprint: UInt64, in processes: [ProcessSample]) -> Double {
        guard let largest = processes.map(\.memoryFootprint).max(), largest > 0 else { return 0 }
        return Double(footprint) / Double(largest)
    }

    private var cachedDetail: String {
        guard let memory else { return "" }
        return "Total \(ByteFormatter.memory(memory.total))"
    }
}

/// App, wired, compressed and free as one bar — the shape of memory use.
private struct CompositionBar: View {
    let memory: MemorySample

    var body: some View {
        // No spacing between the segments: they cover the whole bar by
        // construction, so a gap of even one point overflows the width, and the
        // clip then eats the end of the last segment.
        GeometryReader { geometry in
            HStack(spacing: 0) {
                ForEach(segments, id: \.label) { segment in
                    Rectangle()
                        .fill(segment.colour)
                        .frame(width: geometry.size.width * segment.fraction)
                }
            }
        }
        .frame(height: 10)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private var segments: [CompositionSegment] { CompositionSegment.all(for: memory) }
}

/// Four columns, each a dot and label above its value. Laid out in columns
/// rather than a single row because at 320 points "Compressed" and its number
/// will not sit side by side without one of them wrapping.
private struct CompositionLegend: View {
    let memory: MemorySample

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            ForEach(CompositionSegment.all(for: memory), id: \.label) { segment in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(segment.colour)
                            .frame(width: 6, height: 6)
                        Text(segment.label)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Text(ByteFormatter.memory(segment.bytes))
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// The three numbers that do not fit the composition bar but answer the next
/// question: is it swapping, how much is reclaimable, how full is it.
private struct StatsRow: View {
    let memory: MemorySample

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            stat("Swap", ByteFormatter.memory(memory.swapUsed))
            stat("Cached", ByteFormatter.memory(memory.cached))
            stat("Used", PercentFormatter.string(memory.usedFraction))
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 13))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

}

private struct CompositionSegment {
    let label: String
    let bytes: UInt64
    let fraction: Double
    let colour: Color

    static func all(for memory: MemorySample) -> [CompositionSegment] {
        let total = Double(max(memory.total, 1))
        // The remainder, so the four numbers add up to the total the footer
        // prints and the bar fills its width exactly rather than trailing off a
        // percent short of it.
        let available = memory.available
        return [
            ("App", memory.app, Color(Palette.memory)),
            ("Wired", memory.wired, Color(Palette.disk)),
            ("Compr.", memory.compressed, Color(Palette.cpuEfficiency)),
            ("Available", available, Color(nsColor: .tertiaryLabelColor)),
        ].map { label, bytes, colour in
            CompositionSegment(
                label: label,
                bytes: bytes,
                fraction: Double(bytes) / total,
                colour: colour
            )
        }
    }
}
