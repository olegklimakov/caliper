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
