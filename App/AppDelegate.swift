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
    /// `nil` only when the store could not be opened.
    ///
    /// Built in `init`, not `applicationDidFinishLaunching`: SwiftUI evaluates
    /// the scene graph before the delegate finishes launching, so a value
    /// assigned later is captured as nil for the life of the process.
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
    /// One owner of the Dock tile and the menu bar: the history window and the
    /// updater both put windows up, and either closing must not undress the
    /// other.
    private let activation = ActivationPolicy()
    private var updater: UpdaterService?
    private var updates: Task<Void, Never>?
    private var isDashboardVisible = false
    /// What the open panel is drawing, `nil` when none is. One optional rather
    /// than a flag beside a set, which can disagree.
    private var openPanelMetrics: Set<MetricKind>?

    override init() {
        if let store = try? HistoryStore() {
            history = HistoryReader(store: store)
            recorder = HistoryRecorder(store: store)
            processRecorder = ProcessHistoryRecorder(
                store: store,
                isEnabled: preferences.recordsProcessHistory,
                pinned: preferences.pinnedProcesses
            )
            downsampler = Downsampler(store: store)
        } else {
            // Best-effort: a machine whose store cannot be opened still shows
            // live metrics.
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

        // After the status item, so the dot an immediate update asks for has
        // somewhere to land; before the window, whose settings room draws its
        // switches.
        let updater = UpdaterService(activation: activation)
        updater.onUnseenUpdateChange = { [weak statusItemController] hasUpdate in
            statusItemController?.setUpdateAvailable(hasUpdate)
        }
        statusItemController.onCheckForUpdates = { [weak updater] in
            updater?.checkForUpdates()
        }
        self.updater = updater

        let dashboard = DashboardWindowController(
            metrics: metrics,
            history: history,
            historyActions: historyActions,
            preferences: preferences,
            activation: activation,
            updater: updater
        ) { [weak self] isVisible in
            self?.dashboardVisibilityChanged(isVisible)
        }
        self.dashboard = dashboard

        let panels = PanelController(metrics: metrics, preferences: preferences)
        panels.onOpenChange = { [weak self] drawn in
            self?.openPanelMetrics = drawn
            self?.updateDemand()
        }
        statusItemController.onSelect = { [weak panels] module, button in
            panels?.toggle(module, from: button)
        }
        statusItemController.onSelectCombined = { [weak panels] button in
            panels?.toggleCombined(from: button)
        }
        // Two doors, one call: the status item's right-click menu and a
        // panel's footer button.
        statusItemController.onOpenSettings = { [weak dashboard] in
            dashboard?.show(.settings)
        }
        panels.onOpenSettings = { [weak dashboard] in
            dashboard?.show(.settings)
        }
        panels.onOpenHistory = { [weak dashboard] in
            dashboard?.show(.overview)
        }
        panels.onOpenCard = { [weak dashboard] target in
            dashboard?.show(.process(target))
        }
        preferences.onChange = { [weak statusItemController, preferences, processRecorder] in
            statusItemController?.setLayout(
                preferences.menuBar,
                combined: preferences.combinesModules
            )
            statusItemController?.setColoured(preferences.colouredIndicators)
            processRecorder?.setEnabled(preferences.recordsProcessHistory)
            processRecorder?.setPinned(preferences.pinnedProcesses)
        }
        self.statusItemController = statusItemController
        self.panels = panels

        startRecording()
        becomeVisible()
        observeWorkspace()

        updates = Task { [coordinator, metrics, statusItemController, recorder, processRecorder] in
            let snapshots = await coordinator.snapshots()
            await coordinator.start()
            var watching: Set<String> = []
            for await snapshot in snapshots {
                metrics.update(with: snapshot)
                statusItemController.snapshotDidChange()
                recorder?.record(snapshot)
                // The recorder decides whether this sweep is one it has already
                // folded; a snapshot carries the newest one every tick.
                if let processes = snapshot.processes {
                    processRecorder?.record(processes)
                    // The recorder answers with what it wants named on the next
                    // sweep — its pins, and the names it is still holding after
                    // they fell out of every ranking. Pushing an unchanged set
                    // is a lock the coordinator does not need to take.
                    if let wanted = processRecorder?.watching, wanted != watching {
                        watching = wanted
                        coordinator.setWatching(wanted)
                    }
                }
            }
        }

        // Hidden, like --preview-ui: lets the footprint harness measure the
        // card-open state without driving the UI, which would need
        // Accessibility permission.
        let arguments = CommandLine.arguments
        if let flag = arguments.firstIndex(of: "--open-card"), arguments.indices.contains(flag + 1) {
            dashboard.show(.process(.name(arguments[flag + 1])))
        }
    }

    /// No target, so it travels the responder chain and arrives here: the menu
    /// is installed before the window controller exists.
    @objc func openSettings(_ sender: Any?) {
        dashboard?.show(.settings)
    }

    /// Down the responder chain, the way Settings is.
    @objc func checkForUpdates(_ sender: Any?) {
        updater?.checkForUpdates()
    }

    /// A popover is a window, so closing one — which opening a second panel
    /// does — takes away the app's last window, and AppKit quits an app whose
    /// last window went away. Cleanly, with no crash to point at.
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
            // Every ten minutes keeps each pass small; the finest tier only
            // needs compacting as fast as it fills.
            while !Task.isCancelled {
                // Read each pass: retention is a setting, and a value captured
                // at launch would be honoured until restart.
                let retention = await preferences.processRetention.seconds
                try? await downsampler.compact(processRetention: retention)
                try? await Task.sleep(for: .seconds(600))
            }
        }
    }

    /// `nil` when there is no store to act on.
    var historyActions: HistoryActions? {
        guard let history else { return nil }
        // Strongly: the delegate lives as long as the process, and a weak
        // capture would report *success* to the settings screen if nil.
        return HistoryActions(
            sizeOnDisk: { history.storeSize() },
            deleteProcessHistory: { try await self.deleteProcessHistory() },
            deleteEverything: { try await self.deleteEverything() }
        )
    }

    /// Both the tables and what the recorder still holds in memory, or the
    /// button lies: a bucket and a minute of pending rows would be written
    /// straight back.
    private func deleteProcessHistory() async throws {
        processRecorder?.discardPending()
        // This delete takes the registry with it, and the search room is a
        // list of exactly what it deleted. Deferred for the same reason as
        // below: the rows go in the first statement, so a vacuum that throws
        // still leaves a window drawing a record that is gone.
        defer { NotificationCenter.default.post(name: .historyDidChange, object: nil) }
        try await history?.deleteProcessHistory()
    }

    /// Empties everything recorded and rebuilds the file at its new size.
    ///
    /// Both recorders first, for the reason above, then a notification: a
    /// dashboard reloads on a tenth of its span — eight minutes on the year
    /// view — and until then charts rows that are gone.
    private func deleteEverything() async throws {
        recorder?.discardPending()
        processRecorder?.discardPending()
        // Whether or not the delete finishes: the rows are dropped in the
        // first of two statements, so a vacuum that throws still leaves a
        // window charting history that is gone.
        defer { NotificationCenter.default.post(name: .historyDidChange, object: nil) }
        try await history?.deleteAll()
    }

    private func dashboardVisibilityChanged(_ isVisible: Bool) {
        isDashboardVisible = isVisible
        updateDemand()
        // Before the window's first read, and on this thread for that reason:
        // the registry is written every ten minutes, so a card's start count
        // and the search room's "last seen" would otherwise be up to ten
        // minutes behind the machine — and a card gets opened *because*
        // something is restarting right now.
        if isVisible {
            try? processRecorder?.flushRegistry()
        }
    }

    // MARK: - Activity

    private var areScreensAwake = true

    /// One place decides the sampling rate, from everything that can be looking
    /// at the data at once.
    ///
    /// The menu bar strip contributes nothing — see `MetricDemand.menuBar`.
    /// Only something the user has opened raises a metric, and only the metrics
    /// that surface draws, which keeps a CPU panel from paying for the sensors.
    ///
    /// Set rather than awaited: `setDemand` takes a lock the next tick reads.
    private func updateDemand() {
        // The union, not whichever is uppermost: nothing closes a popover when
        // the window is showing, so a panel over the dashboard is a second
        // surface drawing.
        var drawn = openPanelMetrics ?? []
        if isDashboardVisible {
            drawn.formUnion(DashboardWindowController.drawnMetrics)
        }
        coordinator.setDemand(MetricDemand(isVisible: areScreensAwake, metrics: drawn))
    }

    private func observeWorkspace() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(
            self, selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification, object: nil)
        // The one case where this app can tell nobody is looking without a
        // window of its own being involved.
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
        // Without an assertion the system throttles the timer as soon as the
        // app looks idle, which for a menu bar app is most of the time. With the
        // screens off there is nothing to throttle away from.
        appNap = AppNapAssertion(reason: "Sampling system metrics for the menu bar")
        areScreensAwake = true
        updateDemand()
    }

    @objc private func becomeHidden() {
        appNap = nil
        panels?.close()
        areScreensAwake = false
        updateDemand()
    }
}

extension Notification.Name {
    /// Posted when the store has been emptied under a window that may be
    /// drawing it.
    static let historyDidChange = Notification.Name("com.olegklimakov.caliper.historyDidChange")
}
