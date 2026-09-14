import CaliperCore
import CaliperHistory
import SwiftUI

/// What the settings screen may do to the recorded history. One value rather
/// than three optionals: the size and the two deletes travel together, and none
/// of them is the store itself — clearing has to reach the recorders too.
@MainActor
struct HistoryActions {
    let sizeOnDisk: () -> UInt64
    let deleteProcessHistory: () async throws -> Void
    let deleteEverything: () async throws -> Void
    /// Writes what the process recorder is holding for the registry, so a room
    /// about to read it sees the last ten minutes. Synchronous, because the
    /// read it exists for happens on the very next layout.
    let flushRegistry: () -> Void
}

/// The settings room of the history window — a room rather than a window of its
/// own, because a SwiftUI `Settings` scene opens only through
/// `showSettingsWindow:`, which a status bar menu cannot reach.
struct SettingsPane: View {
    @Environment(\.controlActiveState) private var controlActiveState
    @Bindable var preferences: Preferences
    /// `nil` when the store could not be opened.
    let history: HistoryActions?
    /// The same store the strip reads, so the row shows the icon that is up
    /// there rather than a mock-up of it.
    let metrics: LiveMetrics
    let updater: UpdaterService
    /// nil when there is no store to watch — the rules are still listed and
    /// still editable, they simply have nothing to be evaluated against.
    let alerts: AlertMonitor?
    @State private var confirming: Deletion?
    @State private var deleteError: String?
    @State private var showingAcknowledgements = false
    /// A file-attribute call, so it is read on appear and after either delete
    /// rather than on every render.
    @State private var storeSize: UInt64 = 0

    /// The two deletes ask different questions because they are different
    /// promises: one takes back a behavioural record and leaves the charts
    /// alone, the other empties the file and rebuilds it.
    enum Deletion {
        case processHistory
        case everything

        var title: String {
            switch self {
            case .processHistory: "Delete the recorded process history?"
            case .everything: "Delete everything Caliper has recorded?"
            }
        }

        var message: String {
            switch self {
            case .processHistory:
                "Every stored list of which applications were running is removed. The metric charts are not affected."
            case .everything:
                "Every chart and every process list is removed and the file is rebuilt at its new size. Recording starts again from now."
            }
        }
    }

    init(
        preferences: Preferences,
        history: HistoryActions?,
        metrics: LiveMetrics,
        updater: UpdaterService,
        alerts: AlertMonitor?
    ) {
        self.preferences = preferences
        self.history = history
        self.metrics = metrics
        self.updater = updater
        self.alerts = alerts
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Settings")
                .font(.system(size: 17, weight: .semibold))
                .padding(.horizontal, 20)
                .padding(.top, 20)

            form
        }
        .frame(minWidth: 560, minHeight: 420, alignment: .topLeading)
        // Also on the window coming forward: it is kept when closed, so
        // `onAppear` alone would show the size from the first open.
        .onAppear { storeSize = history?.sizeOnDisk() ?? 0 }
        .onChange(of: controlActiveState) { _, state in
            guard state != .inactive else { return }
            storeSize = history?.sizeOnDisk() ?? 0
        }
    }

    private var form: some View {
        Form {
            // In the order the strip draws them, which is also the order the
            // rows can be dragged into once the modules share an item.
            Section("Menu bar") {
                Toggle("Combine into one item", isOn: $preferences.combinesModules)
                List {
                    ForEach(preferences.menuBar.order, id: \.self) { module in
                        MenuBarModuleRow(preferences: preferences, metrics: metrics, module: module)
                            .moveDisabled(!preferences.combinesModules)
                    }
                    .onMove { source, destination in
                        preferences.menuBar.move(fromOffsets: source, toOffset: destination)
                    }
                }
                .listStyle(.plain)
                .scrollDisabled(true)
                .scrollContentBackground(.hidden)
                // Exactly the rows: a list inside a form keeps its own
                // scroller and traps the pointer on its way down the settings.
                // The 32 points is measured in the running app, because SwiftUI
                // clips silently rather than reporting it did not fit.
                .frame(height: CGFloat(preferences.menuBar.order.count) * 32)
                Toggle("Colour indicators", isOn: $preferences.colouredIndicators)
                Text(menuBarHint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            // Switch, retention and delete visible together: a per-minute log
            // of which applications ran is a behavioural record, and finding out
            // about it later is the wrong way round.
            Section("History") {
                Toggle("Record top processes", isOn: $preferences.recordsProcessHistory)
                Picker("Keep for", selection: $preferences.processRetention) {
                    ForEach(ProcessRetention.allCases) { retention in
                        Text(retention.label).tag(retention)
                    }
                }
                .disabled(!preferences.recordsProcessHistory)
                Text(
                    "Which applications were heaviest, minute by minute. Stored on this Mac and never sent anywhere. Detail at 30-second resolution is kept for a day whatever this says."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                if !preferences.pinnedProcesses.isEmpty {
                    // Listed here as well as on the card: a pin is a standing
                    // instruction to record something, and the place a user
                    // looks for standing instructions is settings, not the
                    // room where they set one months ago.
                    ForEach(preferences.pinnedProcesses.sorted(), id: \.self) { name in
                        LabeledContent(name) {
                            Button("Stop") { preferences.setPinned(false, for: name) }
                        }
                    }
                    Text(pinnedHint)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button("Delete process history…") { confirming = .processHistory }
                    .disabled(history == nil)

                Button("Delete all history…") { confirming = .everything }
                    .disabled(history == nil)
                if let deleteError {
                    Text(deleteError)
                        .font(.footnote)
                        .foregroundStyle(Color(Palette.critical))
                }
            }
            .confirmationDialog(
                confirming?.title ?? "",
                isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                presenting: confirming
            ) { deletion in
                Button("Delete", role: .destructive) { delete(deletion) }
                Button("Cancel", role: .cancel) {}
            } message: { deletion in
                Text(deletion.message)
            }

            AlertsSection(preferences: preferences, monitor: alerts)

            CostSection(selfMetrics: metrics.snapshot?.selfMetrics, storeSize: storeSize)

            Section("General") {
                Toggle("Show Caliper in the Dock", isOn: $preferences.showsDockIcon)
                Text(
                    "Off, Caliper is only in the menu bar, and a Dock tile appears while a window of its own is open. On, it keeps one — which is also how to find the app again when the menu bar is full."
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
                LaunchAtLoginToggle(preferences: preferences)
            }

            updates
            about
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showingAcknowledgements) {
            AcknowledgementsSheet()
        }
    }

    // MARK: - About

    /// Where the third-party notices are reachable from — the only route to
    /// them for someone who downloaded a disk image rather than the source.
    /// `NOTICE` says what is owed to whom.
    private var about: some View {
        Section("About") {
            Text(
                "Caliper is open source under the MIT licence, and is built on GRDB.swift and Sparkle, which are too."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            Button("Acknowledgements…") { showingAcknowledgements = true }
        }
    }

    // MARK: - Updates

    private var updates: some View {
        @Bindable var updater = updater
        return Section("Updates") {
            Toggle("Check automatically", isOn: $updater.automaticallyChecksForUpdates)
            Toggle("Download in the background", isOn: $updater.automaticallyDownloadsUpdates)
                .disabled(!updater.automaticallyChecksForUpdates)
            Text(
                "A downloaded update installs itself the next time Caliper quits. Every update is checked against the developer signature before it is applied."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)

            LabeledContent("Last checked") {
                Text(lastChecked)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            LabeledContent("Version") {
                Text(UpdaterService.version)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Button("Check Now") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
        }
    }

    private var lastChecked: String {
        guard let date = updater.lastUpdateCheckDate else { return "Never" }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    // MARK: - Menu bar

    /// The price, because a pin is the one setting here that makes the file
    /// bigger rather than smaller.
    private var pinnedHint: String {
        let names = preferences.pinnedProcesses.count
        let room = max(Preferences.pinLimit - names, 0)
        return "Recorded in every bucket, whatever they rank. "
            + Decimals.string("%.1f MB", Double(names) * Preferences.megabytesPerPin)
            + " of the store at 14 days, and \(room) more can be pinned."
    }

    /// The ⌘-drag advice is true of separate items only: one item has no items
    /// to drag, which is why its order is ours to keep.
    private var menuBarHint: String {
        preferences.combinesModules
            ? "Every module in one button, and clicking it opens all of them at once. Drag the rows to set the order they are drawn in."
            : "A module can draw its graph, the symbol that names it, or neither — the narrower it is, the more of the menu bar is left for everything else. Drag items in the menu bar with ⌘ held to reorder them."
    }

    private func delete(_ deletion: Deletion) {
        Task {
            do {
                switch deletion {
                case .processHistory: try await history?.deleteProcessHistory()
                case .everything: try await history?.deleteEverything()
                }
                deleteError = nil
            } catch {
                // A delete button that quietly failed leaves the user believing
                // a record is gone when it is not.
                deleteError = error.localizedDescription
            }
            // Worked or not, the number on screen should be what the file now
            // weighs.
            storeSize = history?.sizeOnDisk() ?? 0
        }
    }
}

/// What this app is costing, which is the one question the README answers with
/// a table and every competitor's FAQ answers with "disable some modules".
///
/// **With this window open**, and that is not a caveat that can be dropped:
/// reading the figure is what creates it. Menu-bar-only steady state is a
/// different measurement — half an hour of a release build under
/// `Scripts/footprint_check.sh` — and no number the app can take of itself
/// while being looked at is that one. No figure from the harness is quoted
/// here either: a constant baked into a settings row goes stale silently,
/// where the README's table at least gets read when it is edited.
///
/// A view of its own so the preview harness can render it: `SettingsPane`
/// needs an `UpdaterService`, and constructing one starts Sparkle's updater,
/// which is not a thing a picture should do.
struct CostSection: View {
    let selfMetrics: SelfMetrics?
    let storeSize: UInt64

    var body: some View {
        Section("What Caliper costs") {
            LabeledContent(
                "CPU",
                // Of *one* core, the unit Activity Monitor's %CPU column uses
                // — the same convention this app reports every other process
                // in, and the one the README's table is quoted in.
                value: selfMetrics.map {
                    "\(PercentFormatter.string($0.cpu, decimals: 1)) of one core"
                } ?? "—"
            )
            LabeledContent(
                "Memory",
                value: selfMetrics.map { ByteFormatter.memory($0.memoryFootprint) } ?? "—"
            )
            LabeledContent(
                "Power",
                value: selfMetrics.map { PowerFormatter.string($0.power) } ?? "—"
            )
            LabeledContent("History on disk", value: ByteFormatter.capacity(storeSize))
            Text(
                "What it costs right now, with this window open — which is the expensive state, because opening a window is how you come to read the figure. Menu-bar-only steady state is lower, and is measured over half an hour by the project's own harness rather than by this row."
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }
}
