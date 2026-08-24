import AppKit
import CaliperHistory
import Observation
import SwiftUI

/// Which room of the window is showing.
///
/// Held outside the view so that anything can point the window at a section —
/// the status bar menu is AppKit and cannot reach into a SwiftUI selection, and
/// "open Settings" has to be a property assignment rather than a message the
/// view must be persuaded to receive.
@MainActor
@Observable
final class DashboardNavigation {
    var section: DashboardSection = .overview
}

/// The history window, owned by the app rather than by a scene graph.
///
/// It used to be a SwiftUI `Window` scene, and the settings were a `Settings`
/// scene beside it. Both could only be opened from inside SwiftUI — the panel
/// footer through `@Environment(\.openWindow)`, the settings through
/// `showSettingsWindow:` — and the status bar menu, which is AppKit, could
/// reach neither. That is not a detail: the Settings menu item did nothing at
/// all, and every setting this app had was unreachable.
///
/// Owning the window here gives every caller the same call. The hosting
/// controller is built on first use and kept: unlike a panel, this window holds
/// a query and a refresh clock that should survive being closed and reopened.
@MainActor
final class DashboardWindowController: NSObject, NSWindowDelegate {
    let navigation = DashboardNavigation()

    private let metrics: LiveMetrics
    private let history: HistoryReader?
    private let preferences: Preferences
    /// What the settings room may do to the recorded history.
    private let historyActions: HistoryActions?
    /// Reported so the sampler can run at dashboard rates while the window is
    /// on screen, and drop back when it is not.
    private let onVisibilityChange: (Bool) -> Void

    private var window: NSWindow?

    init(
        metrics: LiveMetrics,
        history: HistoryReader?,
        historyActions: HistoryActions?,
        preferences: Preferences,
        onVisibilityChange: @escaping (Bool) -> Void
    ) {
        self.metrics = metrics
        self.history = history
        self.historyActions = historyActions
        self.preferences = preferences
        self.onVisibilityChange = onVisibilityChange
    }

    /// Opens the window at one of its rooms, or brings it forward if it is
    /// already up.
    func show(_ section: DashboardSection) {
        navigation.section = section
        let window = window ?? makeWindow()
        self.window = window

        // The Dock icon and the menu bar across the top of the screen belong to
        // this window, not to the app: a monitor that lives in the status bar
        // has no business holding a Dock slot while its only window is closed,
        // and a window shown by an accessory app has no visible Quit, no Window
        // menu and no discoverable ⌘W, because an accessory app's main menu is
        // never drawn.
        //
        // Before `activate`, not after: the switch itself reorders the app, and
        // a window brought forward first lands behind whatever was in front.
        NSApp.setActivationPolicy(.regular)
        // A menu bar app is not the active app when someone picks from its
        // menu, and a window ordered front by an inactive app opens behind
        // whatever they were looking at.
        NSApp.activate(ignoringOtherApps: true)
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
                navigation: navigation
            )
        )
        // Where the user last left it, and centred the first time.
        //
        // `setFrameUsingName` is what says whether there *was* a saved frame.
        // Testing the origin does not: a titled window built from a zero-origin
        // content rect comes back at (0, 90) — AppKit has already offset it for
        // the title bar and constrained it to the visible frame — so a window
        // that had never been placed would open flush into the bottom-left
        // corner instead of the middle of the screen.
        if !window.setFrameUsingName("dashboard") {
            // Sized here rather than by the `contentRect` above: assigning the
            // hosting controller shrinks the window to what SwiftUI says it
            // needs, which is the panes' *minimum* — 748 × 612, and a first
            // launch that opens at the smallest size the window allows.
            window.setContentSize(NSSize(width: 1000, height: 640))
            window.center()
        }
        window.setFrameAutosaveName("dashboard")
        // The delegate rather than the view's `onDisappear`: a window that is
        // closed keeps its view tree, so SwiftUI never reports it gone and the
        // sampler would stay at dashboard rates for the life of the process.
        window.delegate = self
        // Released by us, not by AppKit: the controller keeps the window so its
        // loaded history survives a close.
        window.isReleasedWhenClosed = false
        return window
    }

    func windowWillClose(_ notification: Notification) {
        onVisibilityChange(false)
        // After this delegate call returns, not inside it: dropping back to
        // accessory while AppKit is still closing the window leaves the app
        // frontmost with nothing on screen, and the Dock icon outlives the
        // window by a beat.
        //
        // Re-checked rather than assumed: closing and reopening in the same
        // breath — the status bar menu is one click away from doing exactly
        // that — would otherwise land this after `show` and strip the Dock icon
        // and the menu bar off a window that is on screen.
        Task { @MainActor [weak self] in
            guard self?.window?.isVisible != true else { return }
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// Closing is not the only way a window stops being looked at.
    ///
    /// ⌘M and ⌘H leave it open and invisible, and reporting only `willClose`
    /// would hold the sampler at dashboard rates for the rest of the session.
    /// Occlusion covers all of those, including another app's window laid over
    /// this one.
    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        onVisibilityChange(window.occlusionState.contains(.visible))
    }
}
