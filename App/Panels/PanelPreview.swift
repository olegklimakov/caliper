import AppKit
import SwiftUI

/// Renders a panel to an image, so the popovers can be compared against the
/// mockups without a screen recording entitlement or a human clicking each one.
@MainActor
enum PanelPreview {
    static func render(
        _ module: MenuBarModule,
        metrics: LiveMetrics,
        appearance: NSAppearance
    ) -> NSImage? {
        let renderer = ImageRenderer(content: panel(module, metrics: metrics, appearance: appearance))
        renderer.scale = 2
        return renderer.nsImage
    }

    /// The dashboard, at the size it opens in.
    ///
    /// The history is handed in already loaded: `ImageRenderer` draws a view
    /// once and runs none of its tasks, so a pane left to fetch its own samples
    /// would only ever be captured empty.
    static func renderDashboard(
        metrics: LiveMetrics,
        history: DashboardHistory,
        cursor: Date,
        appearance: NSAppearance
    ) -> NSImage? {
        render(
            DashboardPane(metrics: metrics, module: .cpu, preloaded: history, cursor: cursor),
            appearance: appearance,
            // Past the pane's own 560 pt minimum, which grew when the
            // secondary charts landed under the stat cards. Rendering it at 560
            // cropped the row being checked.
            height: 620
        )
    }

    /// The overview, with the cursor parked on the moment worth reading.
    static func renderOverview(
        metrics: LiveMetrics,
        history: DashboardHistory,
        cursor: Date,
        appearance: NSAppearance
    ) -> NSImage? {
        render(
            OverviewPane(metrics: metrics, preloaded: history, cursor: cursor),
            appearance: appearance,
            // Taller than the other panes, at the overview's own minimum: five
            // stacked charts and a list of processes do not fit in what one
            // chart needs, and a preview cropped short would hide the thing it
            // is meant to check.
            height: 620
        )
    }

    /// The combined window, listing whatever the arrangement says is in the
    /// menu bar.
    static func renderCombined(
        metrics: LiveMetrics,
        preferences: Preferences,
        appearance: NSAppearance
    ) -> NSImage? {
        let renderer = ImageRenderer(
            content: CombinedPanel(
                metrics: metrics,
                preferences: preferences,
                openHistory: {},
                openCard: { _ in },
                openSettings: {}
            )
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, appearance.name == .darkAqua ? .dark : .light)
        )
        renderer.scale = 2
        return renderer.nsImage
    }

    /// A module opened from inside the combined window, where its title is the
    /// way back. The affordance replaces the panel's own label, so the only
    /// place it can be checked is a render of the panel itself.
    static func renderDrilled(
        _ module: MenuBarModule,
        metrics: LiveMetrics,
        appearance: NSAppearance
    ) -> NSImage? {
        let renderer = ImageRenderer(
            content: PanelFactory.view(
                for: module,
                metrics: metrics,
                openHistory: {},
                openCard: { _ in },
                onBack: {}
            )
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, appearance.name == .darkAqua ? .dark : .light)
        )
        renderer.scale = 2
        return renderer.nsImage
    }

    @MainActor
    static func renderProcessCard(model: ProcessCardModel, appearance: NSAppearance) -> NSImage? {
        render(ProcessCardPane(model: model, onBack: {}), appearance: appearance, height: 640)
    }

    private static func render(
        _ pane: some View,
        appearance: NSAppearance,
        height: CGFloat = 560
    ) -> NSImage? {
        let renderer = ImageRenderer(
            content: pane
                .frame(width: 820, height: height)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, appearance.name == .darkAqua ? .dark : .light)
        )
        renderer.scale = 1
        return renderer.nsImage
    }

    @ViewBuilder
    private static func panel(
        _ module: MenuBarModule,
        metrics: LiveMetrics,
        appearance: NSAppearance
    ) -> some View {
        // A popover's material cannot be captured off-screen, so the preview
        // stands in the window background colour of the appearance under test.
        PanelFactory.view(for: module, metrics: metrics, openHistory: {}, openCard: { _ in })
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.colorScheme, appearance.name == .darkAqua ? .dark : .light)
    }
}
