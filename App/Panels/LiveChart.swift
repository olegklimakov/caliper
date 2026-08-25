import Charts
import CaliperCore
import SwiftUI

/// A time series drawn with Swift Charts, one line per series.
///
/// Sample index rather than timestamp on the x-axis: these buffers are evenly
/// spaced by construction, and an index axis cannot drift when a tick is
/// dropped.
struct LiveChart: View {
    struct Series: Identifiable {
        let id: String
        let values: [Double]
        let colour: Color
    }

    let series: [Series]
    /// Fixed for fractions, so idle noise does not look like a workload.
    /// `nil` scales to the data, which is what rates need.
    var range: ClosedRange<Double>?
    var filled = false
    /// Panels are too small for axis furniture; the dashboard has room for it,
    /// and a chart you are meant to read values off needs a scale.
    var showsAxes = false
    /// Formats the y-axis labels — percentages, bytes per second or degrees,
    /// depending on what is being charted.
    var axisLabel: ((Double) -> String)?

    var body: some View {
        let domain = range ?? 0...max(upperBound, 1)

        Chart {
            ForEach(series) { line in
                ForEach(Array(line.values.enumerated()), id: \.offset) { index, value in
                    if filled {
                        // A gradient rather than a flat wash: a solid block of
                        // colour under the line reads as a filled bar chart and
                        // buries the line that carries the information.
                        //
                        // Anchored to the foot of the scale, not left to fill to
                        // zero. A temperature chart's domain starts around 33 °C
                        // and zero is nowhere near it, so the area was drawn far
                        // below the plot — eighteen points below the card, over
                        // the rows underneath. Clipping hid that; this is why it
                        // was happening.
                        AreaMark(
                            x: .value("Sample", index),
                            yStart: .value("Floor", domain.lowerBound),
                            yEnd: .value("Value", value)
                        )
                            .foregroundStyle(
                                .linearGradient(
                                    colors: [line.colour.opacity(0.28), line.colour.opacity(0.02)],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                    }
                    // Without an explicit series, Swift Charts treats every
                    // point as one line and joins the end of one series to the
                    // start of the next — a diagonal across the whole chart.
                    LineMark(
                        x: .value("Sample", index),
                        y: .value("Value", value),
                        series: .value("Series", line.id)
                    )
                    .foregroundStyle(line.colour)
                    .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis {
            if showsAxes {
                AxisMarks(position: .trailing) { value in
                    AxisGridLine().foregroundStyle(Color(Palette.gridLine))
                    AxisValueLabel {
                        if let number = value.as(Double.self) {
                            Text(axisLabel?(number) ?? String(format: "%.0f", number))
                                .font(.system(size: 10))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .chartYScale(domain: domain)
        .chartLegend(.hidden)
    }

    private var upperBound: Double {
        series.flatMap(\.values).max() ?? 1
    }
}

/// Download above the axis, upload below it — the network panel's chart.
struct MirroredChart: View {
    let download: [Double]
    let upload: [Double]

    var body: some View {
        let scale = max(download.max() ?? 0, upload.max() ?? 0, 1024)
        VStack(spacing: 1) {
            LiveChart(
                series: [.init(id: "down", values: download, colour: Color(Palette.networkDown))],
                range: 0...scale,
                filled: true
            )
            LiveChart(
                series: [.init(id: "up", values: upload, colour: Color(Palette.networkUp))],
                range: 0...scale,
                filled: true
            )
            .scaleEffect(y: -1, anchor: .center)
        }
    }
}
