import AppKit
import CaliperCore
import CaliperHistory
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Owned here and handed to the scenes directly. Both exist from `init`, so
    /// there is nothing for a scene to wait for and no optional to unwrap.
    let metrics = LiveMetrics()
    let preferences = Preferences()
    /// `nil` only when the store could not be opened at all.
    ///
    /// Built in `init`, not in `applicationDidFinishLaunching`: SwiftUI
    /// evaluates the scene graph before the delegate finishes launching, so a
    /// value assigned later is captured as nil and the window shows "history
    /// unavailable" for the life of the process.
    let history: HistoryReader?

    private let coordinator = SamplingCoordinator()
    private let recorder: HistoryRecorder?
    private let processRecorder: ProcessHistoryRecorder?
    private let downsampler: Downsampler?
    private var compaction: Task<Void, Never>?
    private var statusItemController: StatusItemController?
    private var panels: PanelController?
    private var dashboard: DashboardWindowController?
    private var appNap: AppNapAssertion?
    private var updates: Task<Void, Never>?
    private var isDashboardVisible = false
    private var isPanelOpen = false

    override init() {
        if let store = try? HistoryStore() {
            history = HistoryReader(store: store)
            recorder = HistoryRecorder(store: store)
            processRecorder = ProcessHistoryRecorder(
                store: store,
                isEnabled: preferences.recordsProcessHistory
            )
            downsampler = Downsampler(store: store)
        } else {
            // History is best-effort: a machine whose store cannot be opened —
            // a full disk, a container the app cannot reach — still shows live
            // metrics.
            history = nil
            recorder = nil
            processRecorder = nil
            downsampler = nil
        }
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainMenu.install()

        let statusItemController = StatusItemController(
            metrics: metrics,
            layout: preferences.menuBar,
            combined: preferences.combinesModules
        )
        statusItemController.setColoured(preferences.colouredIndicators)

        let dashboard = DashboardWindowController(
            metrics: metrics,
            history: history,
            historyActions: historyActions,
            preferences: preferences
        ) { [weak self] isVisible in
            self?.dashboardVisibilityChanged(isVisible)
        }
        self.dashboard = dashboard

        let panels = PanelController(metrics: metrics, preferences: preferences)
        panels.onOpenChange = { [weak self, weak statusItemController] isOpen in
            self?.isPanelOpen = isOpen
            statusItemController?.setLive(isOpen)
            self?.updateActivityLevel()
        }
        statusItemController.onSelect = { [weak panels] module, button in
            panels?.toggle(module, from: button)
        }
        statusItemController.onSelectCombined = { [weak panels] button in
            panels?.toggleCombined(from: button)
        }
        // Two doors into the settings, one call: the status item's right-click
        // menu and the Settings button in a panel's footer. History is the
        // third door and opens a different room, below.
        statusItemController.onOpenSettings = { [weak dashboard] in
            dashboard?.show(.settings)
        }
        panels.onOpenSettings = { [weak dashboard] in
            dashboard?.show(.settings)
        }
        panels.onOpenHistory = { [weak dashboard] in
            dashboard?.show(.overview)
        }
        preferences.onChange = { [weak statusItemController, preferences, processRecorder] in
            statusItemController?.setLayout(
                preferences.menuBar,
                combined: preferences.combinesModules
            )
            statusItemController?.setColoured(preferences.colouredIndicators)
            processRecorder?.setEnabled(preferences.recordsProcessHistory)
        }
        self.statusItemController = statusItemController
        self.panels = panels

        startRecording()
        becomeVisible()
        observeWorkspace()

        updates = Task { [coordinator, metrics, statusItemController, recorder, processRecorder] in
            let snapshots = await coordinator.snapshots()
            await coordinator.start()
            for await snapshot in snapshots {
                metrics.update(with: snapshot)
                statusItemController.snapshotDidChange()
                recorder?.record(snapshot)
                // The recorder decides whether this sweep is one it has already
                // folded; a snapshot carries the newest one every tick.
                if let processes = snapshot.processes {
                    processRecorder?.record(processes)
                }
            }
        }
    }

    /// The app menu's Settings item. It carries no target, so it travels the
    /// responder chain and arrives here — the delegate owns the window
    /// controller, and the menu is installed before that controller exists.
    @objc func openSettings(_ sender: Any?) {
        dashboard?.show(.settings)
    }

    /// A popover is a window. Without this, closing one — which is what
    /// happens the moment you open a second panel — closes the app's only
    /// window, and AppKit's default is to quit an app whose last window went
    /// away. The app then vanishes cleanly, with no crash to point at.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        updates?.cancel()
        compaction?.cancel()
        // Synchronous on purpose: the process is about to die, and the
        // alternative is throwing away the last minute of history.
        try? recorder?.flushNow()
        try? processRecorder?.flushNow()
        appNap = nil
    }

    private func startRecording() {
        guard let downsampler else { return }

        compaction = Task.detached(priority: .utility) { [preferences] in
            // Rolling up every ten minutes keeps each pass small; the finest
            // tier only needs compacting as fast as it fills.
            while !Task.isCancelled {
                // Read each pass rather than captured once: retention is a
                // setting, and a pass that used the value from launch would
                // keep honouring it until the app was restarted.
                let retention = await preferences.processRetention.seconds
                try? await downsampler.compact(processRetention: retention)
                try? await Task.sleep(for: .seconds(600))
            }
        }
    }

    /// What the settings screen may do to the recorded history, or `nil` when
    /// there is no store to do it to.
    var historyActions: HistoryActions? {
        guard let history else { return nil }
        // Captured strongly: the delegate lives as long as the process, and a
        // weak capture would have reported *success* to the settings screen if
        // it were ever nil.
        return HistoryActions(
            sizeOnDisk: { history.storeSize() },
            deleteProcessHistory: { try await self.deleteProcessHistory() },
            deleteEverything: { try await self.deleteEverything() }
        )
    }

    /// Empties the recorded process history, including what the recorder is
    /// still holding in memory.
    ///
    /// Both halves, or the button lies: deleting the tables while a bucket and
    /// a minute of pending rows sit in the recorder would write part of the
    /// record straight back.
    private func deleteProcessHistory() async throws {
        processRecorder?.discardPending()
        try await history?.deleteProcessHistory()
    }

    /// Empties everything recorded and rebuilds the file at its new size.
    ///
    /// Both recorders first, for the same reason, and a notification after: a
    /// dashboard left open reloads on a tenth of its span, which is eight
    /// minutes on the year view, and until then it would go on charting rows
    /// that are gone.
    private func deleteEverything() async throws {
        recorder?.discardPending()
        processRecorder?.discardPending()
        // Posted whether or not the delete finishes. The rows are dropped in
        // the first of two statements, so a vacuum that throws still leaves a
        // window charting history that is gone — telling it only on success
        // would leave the failure on screen in the wrong place.
        defer { NotificationCenter.default.post(name: .historyDidChange, object: nil) }
        try await history?.deleteAll()
    }

    private func dashboardVisibilityChanged(_ isVisible: Bool) {
        isDashboardVisible = isVisible
        updateActivityLevel()
    }

    // MARK: - Activity

    private var areScreensAwake = true

    /// One place decides the sampling rate, from everything that can be looking
    /// at the data at once.
    private func updateActivityLevel() {
        let level: ActivityLevel =
            if !areScreensAwake {
                .hidden
            } else if isDashboardVisible {
                .dashboardOpen
            } else if isPanelOpen {
                .panelOpen
            } else {
                .menuBarOnly
            }
        Task { await coordinator.setActivityLevel(level) }
    }

    private func observeWorkspace() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(
            self, selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification, object: nil)
        // A dark display is the one case where this app can tell that nobody is
        // looking without a window of its own being involved.
        workspace.addObserver(
            self, selector: #selector(becomeHidden),
            name: NSWorkspace.screensDidSleepNotification, object: nil)
        workspace.addObserver(
            self, selector: #selector(becomeVisible),
            name: NSWorkspace.screensDidWakeNotification, object: nil)
    }

    /// Counters sampled across sleep describe hours of suspended time, so the
    /// first interval after waking is discarded instead of charted as a spike.
    @objc private func systemDidWake() {
        Task { await coordinator.resetBaselines() }
    }

    @objc private func becomeVisible() {
        // Without an activity assertion the system throttles our timer as soon
        // as the app looks idle to it, which for a menu bar app is most of the
        // time. With the screens off there is nothing to throttle us away from.
        appNap = AppNapAssertion(reason: "Sampling system metrics for the menu bar")
        areScreensAwake = true
        updateActivityLevel()
    }

    @objc private func becomeHidden() {
        appNap = nil
        panels?.close()
        areScreensAwake = false
        updateActivityLevel()
    }
}

extension Notification.Name {
    /// Posted when the store has been emptied under a window that may be
    /// drawing it.
    static let historyDidChange = Notification.Name("com.olegklimakov.caliper.historyDidChange")
}
