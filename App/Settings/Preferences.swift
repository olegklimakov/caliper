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
        static let alertRules = "alertRules"
        static let completedSetup = "completedSetup"
        static let dockIcon = "showsDockIcon"

        /// Every key this app has ever written. Its emptiness is half the
        /// answer to "has this Mac run Caliper before" — see `init`.
        static let all = [
            layout, order, combined, coloured, processHistory, processRetention,
            pinnedProcesses, alertRules, completedSetup, dockIcon,
        ]
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
    /// Cheap but not free — see `megabytesPerPin` — against the ~15 MB the
    /// rankings already take, so the list is bounded rather than open.
    private(set) var pinnedProcesses: Set<String> {
        didSet {
            defaults.set(Array(pinnedProcesses), forKey: Key.pinnedProcesses)
            onChange?()
        }
    }

    static let pinLimit = 10

    /// What one pin costs the store over a fortnight: 30.9 bytes a row
    /// measured by `StoreSizeTests`, a row a bucket, a day of the fine tier
    /// plus fourteen of the minute one.
    static let megabytesPerPin = 0.7

    /// The eleventh is refused rather than silently dropped. Callers ask
    /// `hasRoomForAPin` first, so this is the backstop and not the message.
    func setPinned(_ isPinned: Bool, for name: String) {
        guard isPinned else {
            pinnedProcesses.remove(name)
            return
        }
        guard hasRoomForAPin || pinnedProcesses.contains(name) else { return }
        pinnedProcesses.insert(name)
    }

    var hasRoomForAPin: Bool {
        pinnedProcesses.count < Self.pinLimit
    }

    /// Standing questions about the record — see `AlertRule`.
    ///
    /// JSON rather than a plist shape of its own: a rule has five fields that
    /// travel together and no defaults screen builds one field at a time, so
    /// the shape the type already has is the shape worth storing. A rule that
    /// fails to decode is dropped rather than crashing the launch it is read
    /// on; a silent alert is recoverable, an app that will not start is not.
    private(set) var alertRules: [AlertRule] {
        didSet {
            defaults.set(try? JSONEncoder().encode(alertRules), forKey: Key.alertRules)
            onChange?()
        }
    }

    func addAlertRule(_ rule: AlertRule) {
        alertRules.append(rule)
    }

    func updateAlertRule(_ rule: AlertRule) {
        guard let index = alertRules.firstIndex(where: { $0.id == rule.id }) else { return }
        alertRules[index] = rule
    }

    func removeAlertRule(_ id: UUID) {
        alertRules.removeAll { $0.id == id }
    }

    /// Whether the first-run flow has been through. Stored rather than
    /// inferred: every other setting here has a default, so an empty domain is
    /// what a user who changed nothing looks like, and "have we introduced
    /// ourselves" is not a question a default can answer.
    private(set) var hasCompletedSetup: Bool {
        didSet {
            defaults.set(hasCompletedSetup, forKey: Key.completedSetup)
            // The Dock tile a first run holds is let go here — see
            // `ActivationPolicy.Holder.setup`.
            onChange?()
        }
    }

    func completeSetup() {
        hasCompletedSetup = true
    }

    /// A Dock tile of its own, for people who would rather not hunt for this
    /// app in the menu bar at all.
    ///
    /// Off by default — a status bar monitor has no business holding a Dock slot
    /// with nothing on screen — but the default is what made an install
    /// unfindable, so it is a switch and not a rule. See `ActivationPolicy`.
    var showsDockIcon: Bool {
        didSet {
            defaults.set(showsDockIcon, forKey: Key.dockIcon)
            onChange?()
        }
    }

    /// A direct callback rather than an observation loop: re-arming
    /// `withObservationTracking` leaves a window where an edit is lost.
    var onChange: (() -> Void)?

    private let defaults: UserDefaults

    init(defaults: UserDefaults = DefaultsPolicy.store()) {
        self.defaults = defaults
        Self.settle(defaults)
        hasCompletedSetup = defaults.bool(forKey: Key.completedSetup)
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
        alertRules =
            (defaults.data(forKey: Key.alertRules)
            .flatMap { try? JSONDecoder().decode([AlertRule].self, from: $0) }) ?? []
        showsDockIcon = defaults.bool(forKey: Key.dockIcon)
    }

    /// Decides once, before anything is read, which of three Macs this is.
    ///
    /// *New to Caliper*: nothing stored and no history file. It gets the opening
    /// layout written down — not merely defaulted, or quitting the first-run
    /// flow half way through would leave the third answer below — and is shown
    /// the flow.
    ///
    /// *Running an older Caliper*: the strip up there is its own, whatever it
    /// came from, and an update is no occasion to rearrange it or to introduce
    /// an app it has been running for months. The store file is what says so:
    /// a user who changed no setting has an empty domain and months of history.
    ///
    /// *Already answered*: nothing to do.
    private static func settle(_ defaults: UserDefaults) {
        guard !Key.all.contains(where: { defaults.object(forKey: $0) != nil }) else {
            // Keys but no answer — an install from before this flow existed.
            if defaults.object(forKey: Key.completedSetup) == nil {
                defaults.set(true, forKey: Key.completedSetup)
            }
            return
        }
        // A named domain is one this app has been handed for the occasion, so a
        // store belonging to some other identity is not evidence about it.
        guard DefaultsPolicy.suiteName != nil || !HistoryDatabase.hasStore else {
            defaults.set(true, forKey: Key.completedSetup)
            return
        }
        let opening = MenuBarParts.opening
        defaults.set(opening.stored, forKey: Key.layout)
        defaults.set(opening.storedOrder, forKey: Key.order)
        // One item rather than three: three either fit or are dropped from the
        // right one at a time, and a strip macOS truncated is the failure this
        // whole flow exists to answer for.
        defaults.set(true, forKey: Key.combined)
        defaults.set(false, forKey: Key.completedSetup)
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
