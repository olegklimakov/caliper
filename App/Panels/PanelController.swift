import AppKit
import CaliperCore
import SwiftUI

/// Shows one metric panel at a time, anchored to its menu bar item. The hosting
/// controller is built on open and released on close: rebuilding one is cheap
/// next to keeping five view trees alive.
@MainActor
final class PanelController: NSObject, NSPopoverDelegate {
    private let metrics: LiveMetrics
    /// What the combined window lists, and what its rows draw.
    private let preferences: Preferences
    private var popover: NSPopover?
    private var opened: Opened?

    /// The combined window is not a module and cannot be one — it is every
    /// module at once.
    private enum Opened: Equatable {
        case module(MenuBarModule)
        case combined
    }

    /// What a popover draws, and so what the sampler owes it at full rate.
    ///
    /// Not on `Opened`, because the combined answer needs the preferences: a
    /// strip without Sensors must not be billed for the sweep behind a room it
    /// cannot open.
    private func metrics(of panel: Opened) -> Set<MetricKind> {
        switch panel {
        case .module(let module):
            module.panelMetrics
        // Any room is one click away, and this side never hears about that
        // click, so the window is charged for every room it can reach. The union
        // of the same map rather than "all kinds", so a metric no room draws
        // stays unbilled.
        case .combined:
            preferences.menuBar.enabled.reduce(into: Set<MetricKind>()) {
                $0.formUnion($1.panelMetrics)
            }
        }
    }

    /// Reports what the open panel draws, so the app can raise the sampling
    /// rate for those metrics and no others. `nil` when nothing is open.
    var onOpenChange: ((Set<MetricKind>?) -> Void)?

    /// The history window is the app's to open, not the panel's.
    var onOpenHistory: (() -> Void)?

    /// With one item in the menu bar, a right-click is not the only way in.
    var onOpenSettings: (() -> Void)?

    init(metrics: LiveMetrics, preferences: Preferences) {
        self.metrics = metrics
        self.preferences = preferences
    }

    func toggle(_ module: MenuBarModule, from button: NSStatusBarButton) {
        toggle(.module(module), from: button)
    }

    /// The one item stands for every module, so it opens the window that shows
    /// every module.
    func toggleCombined(from button: NSStatusBarButton) {
        toggle(.combined, from: button)
    }

    private func toggle(_ panel: Opened, from button: NSStatusBarButton) {
        if opened == panel {
            close()
            return
        }
        close()
        show(panel, from: button)
    }

    func close() {
        popover?.performClose(nil)
    }

    private func show(_ panel: Opened, from button: NSStatusBarButton) {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        // The system material, not a painted fill: it is what gives vibrancy
        // and, with it, working Reduce Transparency and Increase Contrast.
        popover.appearance = nil
        popover.delegate = self
        let controller = NSHostingController(rootView: content(for: panel))
        // The popover has to know the panel's height *before* it is shown:
        // otherwise it opens at its old size and grows about its own centre,
        // putting the tallest panel's top 136 points above the menu bar.
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller

        // `.minY`, not `.maxY`: the edge is read in the button's own
        // coordinate space and a status bar button is not flipped, so `.maxY`
        // asks for the popover *above* the menu bar. AppKit flips it back when
        // it can, which hides the mistake for any panel short enough to fit.
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        self.popover = popover
        opened = panel
        onOpenChange?(metrics(of: panel))
    }

    @ViewBuilder
    private func content(for panel: Opened) -> some View {
        switch panel {
        case .module(let module):
            // The app opens the window: a SwiftUI view inside a popover can
            // only reach a scene, and there is no scene graph any more.
            PanelFactory.view(for: module, metrics: metrics, openHistory: openHistory)
        case .combined:
            CombinedPanel(
                metrics: metrics,
                preferences: preferences,
                openHistory: openHistory,
                openSettings: { [weak self] in
                    self?.close()
                    self?.onOpenSettings?()
                }
            )
        }
    }

    private var openHistory: () -> Void {
        { [weak self] in
            self?.close()
            self?.onOpenHistory?()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        // Only for the popover still held: opening a second panel closes the
        // first, and that close arrives *after* the new one is on screen.
        guard let closed = notification.object as? NSPopover, closed === popover else {
            return
        }
        popover?.contentViewController = nil
        popover = nil
        opened = nil
        onOpenChange?(nil)
    }
}
