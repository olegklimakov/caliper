import CaliperCore
import SwiftUI

struct NetworkPanel: View {
    let metrics: LiveMetrics
    let openHistory: () -> Void
    /// Non-nil when this panel is a room of the combined window.
    var onBack: (() -> Void)?

    private var network: NetworkSample? { metrics.snapshot?.network }
    private var connection: ConnectionSample? { metrics.snapshot?.connection }

    var body: some View {
        PanelContainer {
            PanelHeader(
                onBack: onBack,
                title: "Network",
                value: network.map { RateFormatter.panel($0.downloadRate) } ?? "—",
                unit: network == nil ? "" : "down",
                chips: [
                    PanelChip.Model(
                        colour: Color(Palette.networkUp),
                        label: "Up",
                        value: network.map { RateFormatter.panel($0.uploadRate) } ?? "—"
                    )
                ]
            )

            ChartCard {
                MirroredChart(
                    download: Array(metrics.download),
                    upload: Array(metrics.upload)
                )
            }

            if let wifi = connection?.wifi {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Wi-Fi")
                    MetricRow(
                        name: "Signal",
                        value: "\(wifi.rssi) dBm",
                        fraction: signalFraction(wifi.rssi),
                        colour: Color(signalColour(wifi.rssi))
                    )
                    MetricRow(name: "Channel", value: "\(wifi.channel) · \(wifi.band.rawValue)")
                    MetricRow(
                        name: "Link rate",
                        value: "\(Int(wifi.transmitRateMbps)) Mbps"
                    )
                }
            }

            if !activeInterfaces.isEmpty {
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Interfaces")
                    ForEach(activeInterfaces, id: \.name) { interface in
                        MetricRow(
                            name: "\(interface.name)\(addressSuffix(for: interface.name))",
                            // The full form, units and all: the menu bar's
                            // compact "3 K" saves room this row does not need
                            // and leaves the reader to guess at "per second".
                            value: "↓ \(RateFormatter.panel(interface.downloadRate))  ↑ \(RateFormatter.panel(interface.uploadRate))"
                        )
                    }
                }
            }

            Divider()
            PanelFooter(detail: localAddressDetail, openHistory: openHistory)
        }
    }

    /// Everything but loopback and the dozen idle tunnels a Mac keeps open.
    private var activeInterfaces: [NetworkSample.Interface] {
        (network?.interfaces ?? [])
            .filter { !$0.isLoopback }
            .filter { $0.downloadRate > 0 || $0.uploadRate > 0 || hasAddress($0.name) }
            .prefix(4)
            .map { $0 }
    }

    private func hasAddress(_ name: String) -> Bool {
        connection?.addresses.contains { $0.interfaceName == name && !$0.isIPv6 } ?? false
    }

    private func addressSuffix(for name: String) -> String {
        guard let address = connection?.addresses.first(where: { $0.interfaceName == name && !$0.isIPv6 })
        else { return "" }
        return "  \(address.address)"
    }

    private var localAddressDetail: String {
        guard let address = connection?.addresses.first(where: { !$0.isIPv6 && $0.interfaceName != "lo0" })
        else { return "" }
        return "Local \(address.address)"
    }

    /// −50 dBm is excellent, −80 is unusable; the scale between them is what a
    /// signal bar actually means.
    private func signalFraction(_ rssi: Int) -> Double {
        min(1, max(0, Double(rssi + 90) / 40))
    }

    /// A weak signal is never red: the severity palette keeps red for things
    /// that are actually going wrong, and a distant access point is not one.
    private func signalColour(_ rssi: Int) -> NSColor {
        rssi <= -70 ? Palette.warning : Palette.ok
    }
}
