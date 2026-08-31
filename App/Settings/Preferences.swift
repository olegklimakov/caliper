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
        // Not the older `menuBarModules`/`menuBarParts`: a module now stores
        // whether it is in the menu bar at all, and the old shape read under the
        // new rules is an empty strip on first launch. A new key reads as absent
        // and falls back to the defaults.
        static let layout = "menuBarLayout"
        static let order = "menuBarOrder"
        static let combined = "combinedMenuBarItem"
        static let coloured = "colouredIndicators"
        static let processHistory = "recordProcessHistory"
        static let processRetention = "processHistoryRetention"
        static let pinnedProcesses = "pinnedProcesses"
    }

    /// Per module rather than one switch for the strip: a CPU sparkline earns
    /// its width for someone watching a build and is dead space to someone who
    /// only reads the number.
    var menuBar: MenuBarParts {
        didSet {
            defaults.set(menuBar.stored, forKey: Key.layout)
            defaults.set(menuBar.storedOrder, forKey: Key.order)
            onChange?()
        }
    }

    /// Whether the modules share one status item instead of taking one each.
    ///
    /// On a laptop with a notch the bar runs out long before the modules do. One
    /// item draws the same strip and opens one window onto all of it, at the
    /// cost of ⌘-drag — which is why the order becomes ours to keep.
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

    /// On by default: a history nobody switched on is not there when the thing
    /// you wanted to explain has already happened, and this is the half of "what
    /// was going on at 3am" the metric series cannot answer.
    var recordsProcessHistory: Bool {
        didSet {
            defaults.set(recordsProcessHistory, forKey: Key.processHistory)
            onChange?()
        }
    }

    /// A per-minute record of which applications ran is more sensitive than a
    /// CPU percentage, even though it never leaves the machine, so how long it
    /// lives is the user's to set.
    var processRetention: ProcessRetention {
        didSet {
            defaults.set(processRetention.rawValue, forKey: Key.processRetention)
            onChange?()
        }
    }

    /// Names recorded every bucket whatever they rank — the only way a
    /// process's history has no ambiguous gaps in it.
    ///
    /// Cheap but not free: a pinned name costs around 0.7 MB over a fortnight,
    /// against the ~15 MB the rankings already take, so the list is bounded
    /// rather than open.
    private(set) var pinnedProcesses: Set<String> {
        didSet {
            defaults.set(Array(pinnedProcesses), forKey: Key.pinnedProcesses)
            onChange?()
        }
    }

    static let pinLimit = 10

    /// Refuses rather than silently dropping the eleventh: the card has to be
    /// able to say why nothing happened.
    @discardableResult
    func setPinned(_ isPinned: Bool, for name: String) -> Bool {
        guard isPinned else {
            pinnedProcesses.remove(name)
            return true
        }
        guard pinnedProcesses.count < Self.pinLimit || pinnedProcesses.contains(name) else {
            return false
        }
        pinnedProcesses.insert(name)
        return true
    }

    /// A direct callback rather than an observation loop: re-arming
    /// `withObservationTracking` leaves a window where an edit is lost.
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
        pinnedProcesses = Set(defaults.stringArray(forKey: Key.pinnedProcesses) ?? [])
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
