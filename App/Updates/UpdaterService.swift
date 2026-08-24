import Foundation
import Observation
import Sparkle

/// Sparkle's updater, wrapped so the settings screen can observe it.
///
/// Sparkle owns the persisted state — it writes `SUEnableAutomaticChecks` and
/// friends into `UserDefaults` itself — so the properties here are mirrors that
/// write through on `didSet`. Deliberately not part of `Preferences`: a second
/// store of the same switch would only be able to disagree with the first.
///
/// Starting the updater is what schedules background checks and, on first
/// launch, asks whether they are wanted at all; that prompt is Sparkle's own.
@MainActor
@Observable
final class UpdaterService: NSObject, SPUStandardUserDriverDelegate {
    /// False while a check is in flight — the menu item and the button
    /// disable on it.
    private(set) var canCheckForUpdates = false
    private(set) var lastUpdateCheckDate: Date?

    /// An update a scheduled check found and nobody has looked at yet.
    ///
    /// The menu bar shows it rather than a window (see
    /// `supportsGentleScheduledUpdateReminders`), and the strip reads this to
    /// decide whether to mark itself.
    private(set) var hasUnseenUpdate = false

    var automaticallyChecksForUpdates: Bool {
        didSet {
            guard automaticallyChecksForUpdates != oldValue else { return }
            updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
            // Sparkle ties automatic downloads to automatic checks, so the
            // switch above can move the one below with it.
            automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
        }
    }

    /// Sparkle ignores this while automatic checks are off, so the UI hides it
    /// behind the same switch.
    var automaticallyDownloadsUpdates: Bool {
        didSet {
            guard automaticallyDownloadsUpdates != oldValue else { return }
            updater.automaticallyDownloadsUpdates = automaticallyDownloadsUpdates
        }
    }

    /// Called when the badge on the menu bar should appear or go away.
    var onUnseenUpdateChange: ((Bool) -> Void)?

    /// Sparkle's windows need a Dock tile and a menu bar the same way the
    /// history window does, and for the same reason: an accessory app's main
    /// menu is never drawn, so ⌘W and Quit would be missing from a window the
    /// user is expected to read and dismiss.
    @ObservationIgnored private let activation: ActivationPolicy
    @ObservationIgnored private var controller: SPUStandardUpdaterController!
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?

    private var updater: SPUUpdater { controller.updater }

    init(activation: ActivationPolicy) {
        self.activation = activation
        // Placeholders: the real values are read off the updater immediately
        // after it exists, and Swift wants every stored property set before
        // `super.init`.
        automaticallyChecksForUpdates = true
        automaticallyDownloadsUpdates = false
        super.init()

        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: self
        )
        canCheckForUpdates = updater.canCheckForUpdates
        lastUpdateCheckDate = updater.lastUpdateCheckDate
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates

        // `canCheckForUpdates` flips false while a check runs and back when it
        // ends, which also makes it the moment the last-check date is new.
        canCheckObservation = updater.observe(\.canCheckForUpdates, options: [.new]) {
            [weak self] updater, change in
            guard let canCheck = change.newValue else { return }
            // KVO fires outside any actor: hop before touching @MainActor state
            // instead of assuming the thread.
            Task { @MainActor [weak self] in
                guard let self else { return }
                canCheckForUpdates = canCheck
                lastUpdateCheckDate = updater.lastUpdateCheckDate
            }
        }
    }

    /// Asked for by hand, from a menu item or the settings button. Sparkle
    /// shows its window straight away for this one — the user is waiting for an
    /// answer, and "no updates" is an answer.
    func checkForUpdates() {
        clearUnseenUpdate()
        activation.hold(.updater)
        updater.checkForUpdates()
    }

    /// The running build, as `0.1.0 (1)` — the marketing version with the
    /// integer Sparkle actually compares. The one thing worth having in front
    /// of you when reporting a bug.
    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    // MARK: - SPUStandardUserDriverDelegate

    /// A menu bar monitor is watched, not used: it has no window in front of
    /// anyone, and a scheduled check that threw one up would interrupt whatever
    /// the machine is actually for. With this on, Sparkle hands a scheduled
    /// find back here instead of showing it, and the strip carries the news
    /// until the user asks.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // Always ours, and `immediateFocus` is deliberately ignored. It reads
        // like "the user is looking at the app", and it is not: Sparkle sets it
        // when it proposes to take utmost focus, which it does when the app was
        // launched recently or the machine has been idle. Returning it put a
        // window over the screen at every login — the one moment a menu bar
        // monitor is least entitled to one.
        false
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if state.userInitiated {
                activation.hold(.updater)
            } else if !handleShowingUpdate {
                markUnseenUpdate()
            }
        }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            clearUnseenUpdate()
            // Whether the session ended in an install or a "you are up to
            // date", the Dock tile it borrowed goes back.
            activation.release(.updater)
        }
    }

    // MARK: - Badge

    private func markUnseenUpdate() {
        guard !hasUnseenUpdate else { return }
        hasUnseenUpdate = true
        onUnseenUpdateChange?(true)
    }

    private func clearUnseenUpdate() {
        guard hasUnseenUpdate else { return }
        hasUnseenUpdate = false
        onUnseenUpdateChange?(false)
    }
}
