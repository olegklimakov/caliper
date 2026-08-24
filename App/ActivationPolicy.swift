import AppKit

/// Whether the app has a Dock tile and a menu bar across the top of the screen.
///
/// A monitor that lives in the status bar has no business holding a Dock slot
/// while nothing of its own is on screen — but a window shown by an accessory
/// app has no visible Quit, no Window menu and no discoverable ⌘W, because an
/// accessory app's main menu is never drawn. So the app switches, and the
/// switch belongs to whatever is currently showing.
///
/// Which is why this is a set rather than a flag: the history window and
/// Sparkle's update window can both be up at once, and whichever closes first
/// must not strip the Dock icon and the menu bar off the one still open.
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
        // After this call returns, not inside it: dropping back to accessory
        // while AppKit is still closing the window leaves the app frontmost
        // with nothing on screen, and the Dock icon outlives the window by a
        // beat.
        //
        // Re-checked rather than assumed: closing and reopening in the same
        // breath — the status bar menu is one click away from doing exactly
        // that — would otherwise land this after a `hold` and strip the Dock
        // icon and the menu bar off a window that is on screen.
        Task { @MainActor [weak self] in
            guard let self, holders.isEmpty else { return }
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
