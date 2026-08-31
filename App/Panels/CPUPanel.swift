import CaliperCore
import SwiftUI

struct CPUPanel: View {
    let metrics: LiveMetrics
    let openHistory: () -> Void
    let openCard: (ProcessCardTarget) -> Void
    /// Non-nil when this panel is a room of the combined window.
    var onBack: (() -> Void)?

    private var cpu: CPUSample? { metrics.snapshot?.cpu }
    private var clusters: [HostInfo.CoreCluster] { metrics.snapshot?.host.coreClusters ?? [] }

    var body: some View {
        PanelContainer {
            PanelHeader(
                onBack: onBack,
                title: "CPU",
                value: cpu.map { String(Int(($0.total * 100).rounded())) } ?? "—",
                unit: cpu == nil ? "" : "%",
                chips: clusterChips
            )

            ChartCard {
                LiveChart(
                    series: chartSeries,
                    range: 0...1
                )
            }

            if let cores = cpu?.cores, !cores.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Cores")
                    CoreBars(cores: cores, clusters: clusters)
                }
            }

            if let processes = metrics.snapshot?.processes?.topByCPU, !processes.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Top processes")
                    ForEach(processes.prefix(5), id: \.pid) { process in
                        ProcessRowButton(
                            process: process,
                            value: PercentFormatter.string(process.cpu, decimals: 1),
                            // Against one core, the unit the value is in.
                            fraction: min(1, process.cpu),
                            colour: Color(Palette.cpu),
                            openCard: openCard
                        )
                    }
                }
            }

            Divider()
            PanelFooter(detail: loadAverage, openHistory: openHistory)
        }
    }

    /// Cluster names come from the machine — "Performance"/"Efficiency" on some
    /// Macs, "Super"/"Performance" on others — and are absent entirely when the
    /// layout could not be established.
    private var clusterChips: [PanelChip.Model] {
        guard let cpu, cpu.clusters.count == clusters.count else { return [] }
        return zip(clusters, cpu.clusters).map { cluster, load in
            PanelChip.Model(
                colour: Color(colour(forCluster: clusters.firstIndex { $0.name == cluster.name } ?? 0)),
                label: cluster.name,
                value: PercentFormatter.string(load)
            )
        }
    }

    private var chartSeries: [LiveChart.Series] {
        guard !metrics.cpuClusters.isEmpty else {
            return [.init(id: "total", values: Array(metrics.cpuTotal), colour: Color(Palette.cpu))]
        }
        return metrics.cpuClusters.enumerated().map { index, buffer in
            LiveChart.Series(
                id: clusters.indices.contains(index) ? clusters[index].name : "cluster \(index)",
                values: Array(buffer),
                colour: Color(colour(forCluster: index))
            )
        }
    }

    private func colour(forCluster index: Int) -> NSColor {
        index == 0 ? Palette.cpu : Palette.cpuEfficiency
    }

    private var loadAverage: String {
        guard let load = cpu?.loadAverage else { return "" }
        let figures = [load.oneMinute, load.fiveMinutes, load.fifteenMinutes]
            .map { Decimals.string("%.2f", $0) }
        return "Load \(figures.joined(separator: " "))"
    }
}

/// One bar per logical core, grouped so the clusters read as clusters.
private struct CoreBars: View {
    let cores: [Double]
    let clusters: [HostInfo.CoreCluster]

    var body: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(cores.enumerated()), id: \.offset) { index, load in
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color(colour(forCore: index)))
                    .frame(height: max(3, 26 * load))
                    .frame(maxWidth: .infinity)
                    .frame(height: 26, alignment: .bottom)
            }
        }
    }

    private func colour(forCore index: Int) -> NSColor {
        guard let cluster = clusters.firstIndex(where: { $0.coreIndices.contains(index) }) else {
            return Palette.cpu
        }
        return cluster == 0 ? Palette.cpu : Palette.cpuEfficiency
    }
}
