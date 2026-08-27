import Foundation
import Observation
import Sparkle

/// Sparkle's updater, wrapped so the settings screen can observe it.
///
/// Sparkle owns the persisted state, so these properties are mirrors that write
/// through on `didSet`. Not part of `Preferences`: a second store of the same
/// switch could only disagree with the first.
///
/// Starting the updater schedules background checks and, on first launch, puts
/// up Sparkle's own prompt asking whether they are wanted.
@MainActor
@Observable
final class UpdaterService: NSObject, SPUStandardUserDriverDelegate {
    /// The menu item and the button disable on it.
    private(set) var canCheckForUpdates = false
    private(set) var lastUpdateCheckDate: Date?

    /// An update a scheduled check found and nobody has looked at yet. The
    /// strip reads this to mark itself; see
    /// `supportsGentleScheduledUpdateReminders`.
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

    /// When the menu bar badge should appear or go away.
    var onUnseenUpdateChange: ((Bool) -> Void)?

    /// Sparkle's windows need a Dock tile and a menu bar for the reason the
    /// history window does: an accessory app draws no main menu, so ⌘W and Quit
    /// would be missing from a window the user has to read and dismiss.
    @ObservationIgnored private let activation: ActivationPolicy
    @ObservationIgnored private var controller: SPUStandardUpdaterController!
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?

    private var updater: SPUUpdater { controller.updater }

    init(activation: ActivationPolicy) {
        self.activation = activation
        // Placeholders: Swift wants every stored property set before
        // `super.init`, and the real values are read off the updater after.
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

        // It flips false while a check runs and back when it ends, which is
        // also when the last-check date is new.
        canCheckObservation = updater.observe(\.canCheckForUpdates, options: [.new]) {
            [weak self] _, change in
            guard let canCheck = change.newValue else { return }
            // KVO fires outside any actor, so the hop carries the new value and
            // not the updater, which is not Sendable.
            Task { @MainActor [weak self] in
                guard let self else { return }
                canCheckForUpdates = canCheck
                lastUpdateCheckDate = updater.lastUpdateCheckDate
            }
        }
    }

    /// Asked for by hand. Sparkle shows its window straight away for this one:
    /// the user is waiting, and "no updates" is an answer.
    func checkForUpdates() {
        clearUnseenUpdate()
        activation.hold(.updater)
        updater.checkForUpdates()
    }

    /// `0.1.0 (1)` — the marketing version with the integer Sparkle compares.
    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "\(short) (\(build))"
    }

    // MARK: - SPUStandardUserDriverDelegate

    /// A menu bar monitor is watched, not used, so a scheduled check that threw
    /// up a window would interrupt whatever the machine is for. With this on,
    /// Sparkle hands the find back here and the strip carries the news.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // `immediateFocus` is deliberately ignored. It reads like "the user is
        // looking at the app" and is not — Sparkle sets it when it proposes to
        // take utmost focus, which it does after a recent launch or an idle
        // machine. Honouring it put a window on screen at every login.
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
            // Install or "up to date", the borrowed Dock tile goes back.
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
