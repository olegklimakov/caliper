import CaliperCore
import SwiftUI

/// The one place that maps a module to its panel.
///
/// Both the popover controller and the preview harness need this map, and two
/// copies would eventually disagree about which view a module opens.
@MainActor
enum PanelFactory {
    @ViewBuilder
    static func view(
        for module: MenuBarModule,
        metrics: LiveMetrics,
        openHistory: @escaping () -> Void,
        /// Non-nil when the panel is a room of the combined window rather than
        /// a popover of its own.
        onBack: (() -> Void)? = nil
    ) -> some View {
        switch module {
        case .cpu: CPUPanel(metrics: metrics, openHistory: openHistory, onBack: onBack)
        case .memory: MemoryPanel(metrics: metrics, openHistory: openHistory, onBack: onBack)
        case .network: NetworkPanel(metrics: metrics, openHistory: openHistory, onBack: onBack)
        case .disk: DiskPanel(metrics: metrics, openHistory: openHistory, onBack: onBack)
        case .temperature: SensorsPanel(metrics: metrics, openHistory: openHistory, onBack: onBack)
        }
    }
}

extension MenuBarModule {
    /// What this module's panel actually draws.
    ///
    /// Here rather than anywhere else because it is the same fact as the map
    /// above — which view a module opens, and what that view reads — and a fact
    /// kept in two places is two facts. Adding a reading to a panel means
    /// adding its kind here, or the panel will draw a number that only moves
    /// every thirty seconds.
    ///
    /// This is what the sampler is told, so an omission here is a stale panel
    /// and a surplus is CPU spent on a metric nobody is looking at. The whole
    /// point is that opening the CPU panel no longer pays for the sensor sweep.
    var panelMetrics: Set<MetricKind> {
        switch self {
        case .cpu: [.cpu, .processes]
        case .memory: [.memory, .processes]
        // Wi-Fi signal and the local address come from `connection`, and the
        // panel prints both beside the rates.
        case .network: [.network, .connection]
        // The one panel that draws drive wear, and the only reader `driveHealth`
        // has anywhere in the app.
        case .disk: [.diskActivity, .volumes, .driveHealth, .processes]
        case .temperature: [.sensors]
        }
    }
}
