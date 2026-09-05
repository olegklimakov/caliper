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
    @State private var launchesAtLogin: Bool
    @State private var loginError: String?
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
        updater: UpdaterService
    ) {
        self.preferences = preferences
        self.history = history
        self.metrics = metrics
        self.updater = updater
        _launchesAtLogin = State(initialValue: preferences.launchesAtLogin)
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
                        moduleRow(module)
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

                LabeledContent("On disk", value: ByteFormatter.capacity(storeSize))
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

            Section("General") {
                Toggle("Launch at login", isOn: $launchesAtLogin)
                    .onChange(of: launchesAtLogin) { _, enabled in
                        do {
                            try preferences.setLaunchesAtLogin(enabled)
                            loginError = nil
                        } catch {
                            // The system's to refuse, so put the switch back
                            // rather than pretending.
                            loginError = error.localizedDescription
                            launchesAtLogin = preferences.launchesAtLogin
                        }
                    }
                if let loginError {
                    Text(loginError)
                        .font(.footnote)
                        .foregroundStyle(Color(Palette.critical))
                }
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

    private func moduleRow(_ module: MenuBarModule) -> some View {
        HStack(spacing: 12) {
            Toggle(module.title, isOn: enabledBinding(module))
                .frame(width: 104, alignment: .leading)
                .disabled(isLastEnabled(module))
            // Three states rather than a checkbox; see `IndicatorGraphic`.
            Picker("", selection: graphicBinding(module)) {
                Text(module.graphTitle).tag(IndicatorGraphic.graph)
                Text("Icon").tag(IndicatorGraphic.icon)
                Text("Nothing").tag(IndicatorGraphic.off)
            }
            .labelsHidden()
            .frame(width: 116)
            .disabled(!preferences.menuBar[module].isEnabled)
            // A setting *of* the module beside it, not another module.
            Toggle(module.valueTitle, isOn: valueBinding(module))
                .toggleStyle(.checkbox)
                .frame(width: 112, alignment: .leading)
                .disabled(isValueLocked(module))
            Spacer(minLength: 8)
            MenuBarIndicatorPreview(
                module: module,
                parts: preferences.menuBar[module],
                coloured: preferences.colouredIndicators,
                metrics: metrics
            )
            .opacity(preferences.menuBar[module].isEnabled ? 1 : 0.35)
        }
    }

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

    private func enabledBinding(_ module: MenuBarModule) -> Binding<Bool> {
        Binding(
            get: { preferences.menuBar[module].isEnabled },
            set: { preferences.menuBar[module].isEnabled = $0 }
        )
    }

    /// The last module stays: an empty strip has no button to right-click, and
    /// that menu is the only way to the settings and to Quit.
    private func isLastEnabled(_ module: MenuBarModule) -> Bool {
        preferences.menuBar.enabled == [module]
    }

    private func graphicBinding(_ module: MenuBarModule) -> Binding<IndicatorGraphic> {
        Binding(
            get: { preferences.menuBar[module].graphic },
            // The stored value refuses picture-and-number-off and hands the
            // number back, so the checkbox beside this ticks itself.
            set: { preferences.menuBar[module].graphic = $0 }
        )
    }

    private func valueBinding(_ module: MenuBarModule) -> Binding<Bool> {
        Binding(
            get: { preferences.menuBar[module].showsValue },
            set: { preferences.menuBar[module].showsValue = $0 }
        )
    }

    /// With nothing in the picture slot the number is all there is, so it
    /// cannot be switched off.
    private func isValueLocked(_ module: MenuBarModule) -> Bool {
        let parts = preferences.menuBar[module]
        return !parts.isEnabled || parts.graphic == .off
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

/// The very image the menu bar will draw, at the size it will draw it —
/// rendered through the same indicator the status item uses, so there is no
/// second drawing to keep in step.
private struct MenuBarIndicatorPreview: View {
    let module: MenuBarModule
    let parts: ModuleParts
    let coloured: Bool
    let metrics: LiveMetrics

    var body: some View {
        let indicator = module.indicator(parts: parts)
        Image(nsImage: indicator.makeImage(metrics, style: IndicatorStyle(isTemplate: !coloured)))
            .renderingMode(coloured ? .original : .template)
            // Reading the identity is what subscribes this view to the
            // metrics: `makeImage`'s drawing block runs when the image is
            // painted, after the body that would have tracked what it read.
            .id(indicator.identity(metrics))
            // Everything it shows is in the row's own checkboxes and in the
            // status item this is a picture of.
            .accessibilityHidden(true)
    }
}
