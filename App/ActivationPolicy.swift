import AppKit

/// Whether the app has a Dock tile and a menu bar across the top of the screen.
///
/// A status bar monitor has no business holding a Dock slot with nothing on
/// screen, but an accessory app draws no main menu, so a window it shows has no
/// Quit, no Window menu and no discoverable ⌘W. So the app switches with
/// whatever is showing.
///
/// A set rather than a flag: the history window and Sparkle's update window can
/// both be up, and whichever closes first must not undress the other.
@MainActor
final class ActivationPolicy {
    enum Holder: Hashable {
        case dashboard
        case updater
        /// The first-run flow. An app that was just installed should be visible
        /// the ordinary way — a Dock tile, a menu across the top, a window in
        /// front — and going quiet afterwards is what finishing the flow buys.
        case setup
        /// A standing choice rather than something on screen: see
        /// `Preferences.showsDockIcon`.
        case dock

        /// Whether taking this one should bring the app to the front. The Dock
        /// preference is read at launch, and coming forward for it would take
        /// the foreground off whatever the user was doing at login.
        var bringsForward: Bool { self != .dock }
    }

    private var holders: Set<Holder> = []

    /// Becomes a regular app on this holder's behalf, and brings it forward if
    /// that is a holder that should — see `Holder.bringsForward`.
    func hold(_ holder: Holder) {
        holders.insert(holder)
        // Before `activate`, not after: the switch itself reorders the app, and
        // a window brought forward first lands behind whatever was in front.
        NSApp.setActivationPolicy(.regular)
        guard holder.bringsForward else { return }
        // A menu bar app is not the active app when someone picks from its
        // menu, and a window ordered front by an inactive app opens behind
        // whatever they were looking at.
        NSApp.activate(ignoringOtherApps: true)
    }

    func release(_ holder: Holder) {
        holders.remove(holder)
        guard holders.isEmpty else { return }
        // After this call returns: dropping back to accessory while AppKit is
        // still closing the window leaves the app frontmost with nothing on
        // screen. Re-checked rather than assumed, or a close-and-reopen — one
        // click apart in the status bar menu — lands this after a `hold`.
        Task { @MainActor [weak self] in
            guard let self, holders.isEmpty else { return }
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
