import CaliperHistory
import SwiftUI

/// What the settings screen may do to the recorded history.
///
/// One value rather than three optionals threaded separately: the size and the
/// two deletes always travel together, and none of them is the store itself —
/// clearing has to reach the recorders as well, and only the delegate holds
/// both.
@MainActor
struct HistoryActions {
    let sizeOnDisk: () -> UInt64
    let deleteProcessHistory: () async throws -> Void
    let deleteEverything: () async throws -> Void
}

/// The settings room of the history window.
///
/// A room rather than a window of its own. It was a SwiftUI `Settings` scene,
/// which only `showSettingsWindow:` could open — and that did nothing at all
/// from a status bar menu, so every setting this app had was unreachable. The
/// mockup never asked for a second window either: it draws Settings at the foot
/// of the sidebar, under the metrics.
struct SettingsPane: View {
    @Environment(\.controlActiveState) private var controlActiveState
    @Bindable var preferences: Preferences
    /// `nil` when the store could not be opened, which is also when there is
    /// nothing to do to it.
    let history: HistoryActions?
    /// What the menu bar previews draw. The same store the strip itself reads,
    /// so the row shows the icon that is up there rather than a mock-up of it.
    let metrics: LiveMetrics
    let updater: UpdaterService
    @State private var launchesAtLogin: Bool
    @State private var loginError: String?
    @State private var confirming: Deletion?
    @State private var deleteError: String?
    @State private var showingAcknowledgements = false
    /// Read on appear and after either delete, not on every render: it is a
    /// file-attribute call, and the only moments it can change are those.
    @State private var storeSize: UInt64 = 0

    /// Which of the two deletes is being confirmed.
    ///
    /// They ask different questions because they are different promises: one
    /// takes back a behavioural record and leaves the charts alone, the other
    /// empties the file and rebuilds it at its new size.
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
        // On appear and whenever the window comes forward again: the window is
        // kept when it closes, so `onAppear` alone would show whatever the
        // store weighed the first time it was opened.
        .onAppear { storeSize = history?.sizeOnDisk() ?? 0 }
        .onChange(of: controlActiveState) { _, state in
            guard state != .inactive else { return }
            storeSize = history?.sizeOnDisk() ?? 0
        }
    }

    private var form: some View {
        Form {
            // One row per module: whether it is up there, which halves it
            // draws, and a live picture of the result — in the order the strip
            // draws them, which is also the order the rows can be dragged into
            // once the modules share an item.
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
                // Exactly the rows, so no row is clipped and none is reachable
                // only by scrolling: a list inside a form is a list, and one
                // that keeps its own scroller traps the pointer on its way down
                // the settings. The row height is measured in the running app —
                // a row holding a picker is 32 points — because SwiftUI will
                // clip silently rather than report that it did not fit.
                .frame(height: CGFloat(preferences.menuBar.order.count) * 32)
                Toggle("Colour indicators", isOn: $preferences.colouredIndicators)
                Text(menuBarHint)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            // The switch, the retention and the delete button in one place and
            // visible together. A per-minute log of which applications ran is a
            // behavioural record, and finding out about it later — from a
            // setting buried somewhere else — is the wrong way round.
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
                            // The registration is the system's to refuse, so say
                            // so and put the switch back rather than pretending.
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
            // Three states rather than a checkbox: with the picture gone,
            // "8 %" and "65 %" are two anonymous percentages, and the symbol is
            // what names a number for twelve points instead of twenty-eight.
            Picker("", selection: graphicBinding(module)) {
                Text(module.graphTitle).tag(IndicatorGraphic.graph)
                Text("Icon").tag(IndicatorGraphic.icon)
                Text("Nothing").tag(IndicatorGraphic.off)
            }
            .labelsHidden()
            .frame(width: 116)
            .disabled(!preferences.menuBar[module].isEnabled)
            // A checkbox rather than a switch: this is a setting *of* the
            // module beside it, not another module.
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

    /// The ⌘-drag advice is true of separate items only: one item has no items
    /// to drag, which is exactly why its order is ours to keep.
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

    /// The last module in the menu bar stays there. An empty strip is an app
    /// with no button to right-click, and the menu behind that button is the
    /// only way to the settings and to Quit.
    private func isLastEnabled(_ module: MenuBarModule) -> Bool {
        preferences.menuBar.enabled == [module]
    }

    private func graphicBinding(_ module: MenuBarModule) -> Binding<IndicatorGraphic> {
        Binding(
            get: { preferences.menuBar[module].graphic },
            // Asking for no picture with no number would leave an empty status
            // item; the stored value refuses that and hands the number back, so
            // the checkbox beside this ticks itself.
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
    /// cannot be switched off — and a module that is not in the menu bar has
    /// nothing to configure at all.
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
                // Said rather than swallowed: a delete button that quietly
                // failed would leave the user believing a record is gone when
                // it is not.
                deleteError = error.localizedDescription
            }
            // Whether it worked or not: the number on screen should be what the
            // file now weighs, not what it weighed before the attempt.
            storeSize = history?.sizeOnDisk() ?? 0
        }
    }
}

/// The very image the menu bar will draw, at the size it will draw it.
///
/// Which half of a module to switch off is a question about how the strip will
/// look, and answering it by reading two checkbox labels and then going up to
/// the menu bar to see what happened is the long way round. Rendered through
/// the same indicator the status item uses, so there is no second drawing of
/// the icon to keep in step with the first.
private struct MenuBarIndicatorPreview: View {
    let module: MenuBarModule
    let parts: ModuleParts
    let coloured: Bool
    let metrics: LiveMetrics

    var body: some View {
        let indicator = module.indicator(parts: parts)
        Image(nsImage: indicator.makeImage(metrics, style: IndicatorStyle(isTemplate: !coloured)))
            .renderingMode(coloured ? .original : .template)
            // Reading the identity is what subscribes this view to the metrics.
            // `makeImage` hands AppKit a drawing block that runs when the image
            // is painted, which is after the body that would have tracked what
            // it read — without this the preview would draw once and then sit
            // at whatever the values were when the window opened.
            .id(indicator.identity(metrics))
            // Everything it shows is in the row's own checkboxes and in the
            // status item this is a picture of.
            .accessibilityHidden(true)
    }
}
