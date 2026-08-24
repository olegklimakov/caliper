import CaliperCore
import SwiftUI

struct DiskPanel: View {
    let metrics: LiveMetrics
    let openHistory: () -> Void
    /// Non-nil when this panel is a room of the combined window.
    var onBack: (() -> Void)?

    private var volumes: [VolumeSample] { metrics.snapshot?.volumes ?? [] }
    private var activity: DiskActivitySample? { metrics.snapshot?.diskActivity }

    var body: some View {
        PanelContainer {
            PanelHeader(
                onBack: onBack,
                title: "Disk",
                value: primary.map { ByteFormatter.capacity($0.availableCapacity) } ?? "—",
                unit: primary == nil ? "" : "free",
                chips: throughputChips
            )

            if let primary {
                CapacityRing(volume: primary)
            }

            ChartCard {
                LiveChart(
                    series: [
                        .init(id: "read", values: Array(metrics.diskRead), colour: Color(Palette.disk)),
                        .init(
                            id: "write",
                            values: Array(metrics.diskWrite),
                            colour: Color(Palette.cpuEfficiency)
                        ),
                    ],
                    // The same floor the other rate charts use, so a quiet disk
                    // draws a flat line instead of amplified noise.
                    range: 0...max(
                        metrics.diskRead.max() ?? 0,
                        metrics.diskWrite.max() ?? 0,
                        1024
                    )
                )
            }

            if volumes.count > 1 {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Volumes")
                    ForEach(volumes, id: \.mountPoint) { volume in
                        MetricRow(
                            name: volume.name,
                            value: ByteFormatter.capacity(volume.availableCapacity),
                            fraction: usedFraction(of: volume),
                            colour: Color(Palette.disk)
                        )
                    }
                }
            }

            if let processes = metrics.snapshot?.processes?.topByDisk, !processes.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Most active")
                    ForEach(processes.prefix(4), id: \.pid) { process in
                        MetricRow(
                            name: process.name,
                            value: RateFormatter.panel(process.diskRate),
                            fraction: activityFraction(of: process.diskRate),
                            colour: Color(Palette.disk)
                        )
                    }
                }
            }

            if let health = metrics.snapshot?.driveHealth {
                Divider()
                DriveHealthSection(health: health)
            }

            Divider()
            PanelFooter(detail: deviceDetail, openHistory: openHistory)
        }
    }

    /// The volume the user thinks of as "the disk": the one the system booted
    /// from, which `mountedVolumeURLs` reports at the root.
    private var primary: VolumeSample? {
        volumes.first { $0.mountPoint == "/" } ?? volumes.first
    }

    private var throughputChips: [PanelChip.Model] {
        guard let activity else { return [] }
        return [
            PanelChip.Model(
                colour: Color(Palette.disk),
                label: "Read",
                value: RateFormatter.panel(activity.readRate)
            ),
            PanelChip.Model(
                colour: Color(Palette.cpuEfficiency),
                label: "Write",
                value: RateFormatter.panel(activity.writeRate)
            ),
        ]
    }

    private func usedFraction(of volume: VolumeSample) -> Double {
        volume.totalCapacity > 0
            ? Double(volume.usedCapacity) / Double(volume.totalCapacity)
            : 0
    }

    /// Against the busiest process, so the bars compare the list to itself
    /// rather than to a device maximum nobody knows.
    private func activityFraction(of rate: Double) -> Double {
        guard let busiest = metrics.snapshot?.processes?.topByDisk.first?.diskRate, busiest > 0
        else { return 0 }
        return rate / busiest
    }

    private var deviceDetail: String {
        activity?.devices.first?.name ?? ""
    }
}

private struct CapacityRing: View {
    let volume: VolumeSample

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(.quaternary, lineWidth: 8)
                Circle()
                    .trim(from: 0, to: usedFraction)
                    .stroke(
                        Color(Palette.disk),
                        style: StrokeStyle(lineWidth: 8, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                Text(PercentFormatter.string(usedFraction))
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
            }
            .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 2) {
                Text(volume.name)
                    .font(.system(size: 13, weight: .medium))
                Text("\(ByteFormatter.capacity(volume.usedCapacity)) of \(ByteFormatter.capacity(volume.totalCapacity))")
                    .font(.system(size: 11))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var usedFraction: Double {
        volume.totalCapacity > 0 ? Double(volume.usedCapacity) / Double(volume.totalCapacity) : 0
    }
}

/// SMART, best effort: absent on Macs whose storage does not expose it.
private struct DriveHealthSection: View {
    let health: DriveHealth

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionLabel("Drive health")
                Spacer()
                PanelChip(
                    model: .init(
                        colour: Color(health.hasCriticalWarning ? Palette.critical : Palette.ok),
                        label: "",
                        value: health.hasCriticalWarning ? "Warning" : "Verified"
                    )
                )
            }
            MetricRow(
                name: "Life used",
                value: PercentFormatter.string(health.lifeUsed),
                fraction: health.lifeUsed,
                colour: Color(Palette.disk)
            )
            if let celsius = health.celsius {
                MetricRow(name: "Temperature", value: TemperatureFormatter.string(celsius))
            }
            MetricRow(name: "Power cycles", value: "\(health.powerCycles)")
        }
    }
}
