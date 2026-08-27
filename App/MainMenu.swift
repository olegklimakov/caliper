import AppKit

/// The menu bar an app gets for free from `SwiftUI.App` and not from a bare
/// AppKit bootstrap.
///
/// Key equivalents resolve through `NSApp.mainMenu`, so without this ⌘C, ⌘V,
/// ⌘X, ⌘A, ⌘Z and ⌘W are dead in the history window and a settings text field
/// cannot be pasted into. The menu is only *drawn* while the app is `.regular`,
/// but resolves either way — which is why its absence was easy to miss.
///
/// Only the items that do something: this app has no documents to open, nothing
/// to print and nothing to find. The app menu is the exception and carries what
/// macOS puts there, because a key equivalent only exists if an item carries
/// it.
@MainActor
enum MainMenu {
    static func install() {
        let menu = NSMenu()
        menu.addItem(application())
        menu.addItem(edit())
        menu.addItem(window())
        NSApp.mainMenu = menu
    }

    private static func application() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu()
        menu.addItem(
            withTitle: "About Caliper",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        menu.addItem(
            withTitle: "Check for Updates…",
            action: #selector(AppDelegate.checkForUpdates(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        // Targetless like the edit items: the responder chain ends at the app
        // delegate, which is the one object that can reach the window.
        menu.addItem(
            withTitle: "Settings…",
            action: #selector(AppDelegate.openSettings(_:)),
            keyEquivalent: ","
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Hide Caliper",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        let hideOthers = NSMenuItem(
            title: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(hideOthers)
        menu.addItem(
            withTitle: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: ""
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit Caliper",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        item.submenu = menu
        return item
    }

    private static func edit() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Edit")
        // Targetless on purpose: they travel the responder chain to whatever
        // field is first responder, which is the only thing that knows how to
        // do them.
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        menu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(
            withTitle: "Select All",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )
        item.submenu = menu
        return item
    }

    private static func window() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Window")
        menu.addItem(
            withTitle: "Close",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        menu.addItem(
            withTitle: "Minimise",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        )
        item.submenu = menu
        NSApp.windowsMenu = menu
        return item
    }
}
