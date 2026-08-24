import Foundation
import CaliperHistory
import Observation
import ServiceManagement

/// User choices, stored in `UserDefaults` and observed by the surfaces that
/// care.
@MainActor
@Observable
final class Preferences {
    private enum Key {
        // Not the older `menuBarModules`/`menuBarParts`: what a module stores
        // now includes whether it is in the menu bar at all, and reading the
        // old shape under the new rules would take every module for switched
        // off — an empty strip on first launch. A new name reads as absent and
        // falls back to the defaults, which is what a format change means.
        static let layout = "menuBarLayout"
        static let order = "menuBarOrder"
        static let combined = "combinedMenuBarItem"
        static let coloured = "colouredIndicators"
        static let processHistory = "recordProcessHistory"
        static let processRetention = "processHistoryRetention"
    }

    /// The whole arrangement of the menu bar: which modules are up there, in
    /// what order, and which halves of each icon are drawn.
    ///
    /// Per module rather than one switch for the strip: a CPU sparkline earns
    /// its width for someone watching a build and is dead space to someone who
    /// only reads the number, and the two are often the same person on
    /// different days.
    var menuBar: MenuBarParts {
        didSet {
            defaults.set(menuBar.stored, forKey: Key.layout)
            defaults.set(menuBar.storedOrder, forKey: Key.order)
            onChange?()
        }
    }

    /// Whether the modules share one status item instead of taking one each.
    ///
    /// Five items is five click targets and five separate popovers, and on a
    /// laptop with a notch the bar runs out long before the modules do. One
    /// item draws the same strip and opens one window onto all of it — at the
    /// cost of ⌘-drag, which is why the order becomes ours to keep.
    var combinesModules: Bool {
        didSet {
            defaults.set(combinesModules, forKey: Key.combined)
            onChange?()
        }
    }

    /// Template rendering is the default: it matches the rest of the menu bar
    /// and stays legible on every wallpaper. Colour is for people who scan the
    /// strip rather than read it.
    var colouredIndicators: Bool {
        didSet {
            defaults.set(colouredIndicators, forKey: Key.coloured)
            onChange?()
        }
    }

    /// Whether the top processes of each bucket are written to the history.
    ///
    /// On by default. A history nobody switched on is not there when the thing
    /// you wanted to explain has already happened — and this is the half of
    /// "what was going on at 3am" that the metric series cannot answer.
    var recordsProcessHistory: Bool {
        didSet {
            defaults.set(recordsProcessHistory, forKey: Key.processHistory)
            onChange?()
        }
    }

    /// How long the minute-resolution process log is kept.
    ///
    /// A per-minute record of which applications ran is categorically more
    /// sensitive than a CPU percentage, even though it never leaves the machine,
    /// so how long it lives is the user's to set.
    var processRetention: ProcessRetention {
        didSet {
            defaults.set(processRetention.rawValue, forKey: Key.processRetention)
            onChange?()
        }
    }

    /// Called after any change lands. A direct callback rather than an
    /// observation loop: re-arming `withObservationTracking` leaves a window
    /// between the change and the next arm, where an edit is simply lost.
    var onChange: (() -> Void)?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        menuBar = MenuBarParts(
            stored: defaults.dictionary(forKey: Key.layout) as? [String: [String]] ?? [:],
            order: defaults.array(forKey: Key.order) as? [String] ?? []
        )
        combinesModules = defaults.bool(forKey: Key.combined)
        colouredIndicators = defaults.bool(forKey: Key.coloured)
        // `bool(forKey:)` reads a missing key as false, which would make the
        // default off rather than on.
        recordsProcessHistory = defaults.object(forKey: Key.processHistory) as? Bool ?? true
        processRetention =
            (defaults.string(forKey: Key.processRetention).flatMap(ProcessRetention.init(rawValue:)))
            ?? .week
    }

    // MARK: - Launch at login

    /// `SMAppService` keeps the registration in the app itself, so there is no
    /// helper bundle to install and nothing left behind if the app is deleted.
    var launchesAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    func setLaunchesAtLogin(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
