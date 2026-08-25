import AppKit
import CaliperCore
import SwiftUI

/// Shows one metric panel at a time, anchored to its menu bar item.
///
/// The hosting controller is built when a panel opens and released when it
/// closes: a popover nobody is looking at should not be holding onto a view
/// tree, and rebuilding one is cheap next to keeping five alive.
@MainActor
final class PanelController: NSObject, NSPopoverDelegate {
    private let metrics: LiveMetrics
    /// What the combined window lists, and what its rows draw.
    private let preferences: Preferences
    private var popover: NSPopover?
    private var opened: Opened?

    /// What is in the popover. The combined window is not a module and cannot
    /// be one — it is every module at once.
    private enum Opened: Equatable {
        case module(MenuBarModule)
        case combined
    }

    /// What a popover draws, and so what the sampler owes it at full rate.
    ///
    /// Not on `Opened`, because the combined answer needs the preferences: the
    /// window lists the modules the user has switched on and no others, so a
    /// strip without Sensors must not be billed for the sweep behind a room it
    /// cannot open.
    private func metrics(of panel: Opened) -> Set<MetricKind> {
        switch panel {
        case .module(let module):
            module.panelMetrics
        // Every enabled module's summary at once, and any of their rooms one
        // click away — a click this side never hears about, so the window is
        // charged for every room it can reach. The union of the same map rather
        // than "all kinds", so a metric no room draws stays unbilled.
        case .combined:
            preferences.menuBar.enabled.reduce(into: Set<MetricKind>()) {
                $0.formUnion($1.panelMetrics)
            }
        }
    }

    /// Reports what the open panel draws, so the app can raise the sampling
    /// rate for those metrics and no others. `nil` when nothing is open.
    var onOpenChange: ((Set<MetricKind>?) -> Void)?

    /// Called when a panel's History affordance is used. The window is the
    /// app's to open, not the panel's.
    var onOpenHistory: (() -> Void)?

    /// Called when the combined window's Settings affordance is used. With one
    /// item in the menu bar, a right-click on it is no longer the only way in.
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
        // The popover has to know how tall the panel is *before* it is shown.
        // Without this it opens at whatever size it had, then grows as SwiftUI
        // reports its layout — and it grows about its own centre, so the tallest
        // panel came up with its top 136 points above the menu bar and clipped
        // by the edge of the screen.
        controller.sizingOptions = [.preferredContentSize]
        popover.contentViewController = controller

        // `.minY`, not `.maxY`. The edge is read in the button's own coordinate
        // space, and a status bar button is not flipped — so `.maxY` asks for
        // the popover to appear *above* the menu bar, off the top of the
        // screen. AppKit flips it back down when it has to, which hid the
        // mistake for every panel short enough to fit either way; the memory
        // panel is 508 points tall and came up clipped by 55.
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        self.popover = popover
        opened = panel
        onOpenChange?(metrics(of: panel))
    }

    @ViewBuilder
    private func content(for panel: Opened) -> some View {
        switch panel {
        case .module(let module):
            // The popover gets out of the way and the app opens the window: a
            // SwiftUI view inside a popover can only reach a scene, and there is
            // no scene graph any more.
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
        // Only if this is the popover we are still holding. Opening a second
        // panel closes the first, and that close arrives *after* the new one is
        // on screen — clearing state blindly would tear down the panel the user
        // just opened.
        guard let closed = notification.object as? NSPopover, closed === popover else {
            return
        }
        popover?.contentViewController = nil
        popover = nil
        opened = nil
        onOpenChange?(nil)
    }
}
