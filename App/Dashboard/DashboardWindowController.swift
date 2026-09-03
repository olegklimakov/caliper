import AppKit
import CaliperCore
import CaliperHistory
import Observation
import SwiftUI

/// Which room of the window is showing. Held outside the view because the
/// status bar menu is AppKit and cannot reach into a SwiftUI selection.
@MainActor
@Observable
final class DashboardNavigation {
    var section: DashboardSection = .overview {
        didSet {
            if case .process = section {} else { returnSection = section }
        }
    }

    /// Where ‹ goes from a card: the last room that was not one.
    private(set) var returnSection: DashboardSection = .overview
}

/// The history window, owned by the app rather than by a scene graph: SwiftUI
/// `Window` and `Settings` scenes can only be opened from inside SwiftUI, and
/// the status bar menu is AppKit.
///
/// The hosting controller is built on first use and kept — unlike a panel, this
/// window holds a query and a refresh clock that should survive a close.
@MainActor
final class DashboardWindowController: NSObject, NSWindowDelegate {
    /// What this window draws live rather than out of the history store: the
    /// sidebar's summary column and the settings room's menu bar previews.
    ///
    /// The bill this window sends the sampler, like `MenuBarModule.panelMetrics`
    /// — a stale entry is a frozen number or CPU spent on nothing. Kept complete
    /// rather than pruned to the kinds whose rate would actually change, so it
    /// does not have to be revisited when the cadence table moves.
    static let drawnMetrics: Set<MetricKind> = [
        .cpu, .memory, .network, .diskActivity, .volumes, .sensors,
        // The process card reads both beside the process it is about.
        .gpuDevice, .power,
    ]

    let navigation = DashboardNavigation()

    private let metrics: LiveMetrics
    private let history: HistoryReader?
    private let preferences: Preferences
    /// What the settings room may do to the recorded history.
    private let historyActions: HistoryActions?
    /// Shared with the updater, which puts up windows of its own.
    private let activation: ActivationPolicy
    private let updater: UpdaterService
    /// Lets the sampler run at dashboard rates only while the window is up.
    private let onVisibilityChange: (Bool) -> Void

    private var window: NSWindow?

    init(
        metrics: LiveMetrics,
        history: HistoryReader?,
        historyActions: HistoryActions?,
        preferences: Preferences,
        activation: ActivationPolicy,
        updater: UpdaterService,
        onVisibilityChange: @escaping (Bool) -> Void
    ) {
        self.metrics = metrics
        self.history = history
        self.historyActions = historyActions
        self.preferences = preferences
        self.activation = activation
        self.updater = updater
        self.onVisibilityChange = onVisibilityChange
    }

    /// Opens the window at one of its rooms, or brings it forward.
    func show(_ section: DashboardSection) {
        navigation.section = section
        let window = window ?? makeWindow()
        self.window = window

        // The Dock icon and the menu bar belong to the windows that are
        // showing, not to the app; see `ActivationPolicy`.
        activation.hold(.dashboard)
        window.makeKeyAndOrderFront(nil)
        onVisibilityChange(true)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Caliper"
        window.contentViewController = NSHostingController(
            rootView: DashboardView(
                metrics: metrics,
                history: history,
                preferences: preferences,
                historyActions: historyActions,
                updater: updater,
                navigation: navigation
            )
        )
        // `setFrameUsingName`'s return is what says whether there *was* a
        // saved frame. Testing the origin does not: a titled window built from
        // a zero-origin content rect comes back at (0, 90), already offset for
        // the title bar.
        if !window.setFrameUsingName("dashboard") {
            // Not the `contentRect` above: assigning the hosting controller
            // shrinks the window to the panes' *minimum*, 748 × 612.
            window.setContentSize(NSSize(width: 1000, height: 640))
            window.center()
        }
        window.setFrameAutosaveName("dashboard")
        // The delegate rather than the view's `onDisappear`: a closed window
        // keeps its view tree, so SwiftUI never reports it gone.
        window.delegate = self
        // The controller keeps the window so its loaded history survives a
        // close.
        window.isReleasedWhenClosed = false
        return window
    }

    func windowWillClose(_ notification: Notification) {
        onVisibilityChange(false)
        activation.release(.dashboard)
        // A closed window keeps its view tree, so a card's `onDisappear` — the
        // probe's stop — would never fire. Leaving the card room is what fires
        // it, and reopening on a live pane instead of a stale card is also the
        // less surprising return.
        if case .process = navigation.section {
            navigation.section = navigation.returnSection
        }
    }

    /// ⌘M and ⌘H leave a window open and invisible, which `willClose` never
    /// reports. `isVisible` as well as the occlusion bit: these arrive
    /// asynchronously and one can land *after* `windowWillClose`, reporting a
    /// window that is already gone as visible.
    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        onVisibilityChange(window.isVisible && window.occlusionState.contains(.visible))
    }
}
