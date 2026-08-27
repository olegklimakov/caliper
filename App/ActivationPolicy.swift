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
    }

    private var holders: Set<Holder> = []

    /// Becomes a regular app on this holder's behalf and brings it forward.
    func hold(_ holder: Holder) {
        holders.insert(holder)
        // Before `activate`, not after: the switch itself reorders the app, and
        // a window brought forward first lands behind whatever was in front.
        NSApp.setActivationPolicy(.regular)
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
