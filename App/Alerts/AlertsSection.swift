import CaliperHistory
import SwiftUI

/// The rules the user has standing, and the one row that makes another.
///
/// A view of its own for the same reason `CostSection` is: the settings pane
/// needs an `UpdaterService` and building one starts Sparkle, so this is the
/// part `--preview-ui` can draw.
struct AlertsSection: View {
    @Bindable var preferences: Preferences
    /// nil in the preview harness, which has no notification centre and no
    /// timer to drive.
    let monitor: AlertMonitor?

    /// Folded away until asked for, which is both the tidier row and the only
    /// way this section renders off-screen at all: a `TextField` is AppKit
    /// underneath and `ImageRenderer` draws those as a placeholder.
    @State private var isAdding = false
    @State private var draft = Draft()

    /// The rule being built, in the units it is typed in rather than the SI the
    /// rule stores.
    private struct Draft {
        var series: MetricSeries = .cpu
        var comparison: AlertComparison = .above
        var entered = 80.0
        var duration: TimeInterval = 300
    }

    var body: some View {
        Section("Alerts") {
            ForEach(preferences.alertRules) { rule in
                LabeledContent(AlertRuleText.sentence(rule)) {
                    Toggle("", isOn: binding(for: rule))
                        .labelsHidden()
                    Button("Remove") {
                        monitor?.ruleChanged(rule.id)
                        preferences.removeAlertRule(rule.id)
                    }
                }
            }

            if isAdding {
                Picker("When", selection: $draft.series) {
                    ForEach(MetricSeries.allCases, id: \.self) { series in
                        Text(MetricSeriesText.name(series)).tag(series)
                    }
                }
                Picker("Is", selection: $draft.comparison) {
                    Text("over").tag(AlertComparison.above)
                    Text("under").tag(AlertComparison.below)
                }
                LabeledContent("Threshold") {
                    HStack {
                        TextField("", value: $draft.entered, format: .number)
                            .frame(width: 70)
                        Text(MetricSeriesText.entryUnit(draft.series))
                            .foregroundStyle(.secondary)
                    }
                }
                Picker("For", selection: $draft.duration) {
                    ForEach(AlertRule.durations, id: \.self) { duration in
                        Text(DurationFormatter.brief(duration)).tag(duration)
                    }
                }
                HStack {
                    Button("Cancel") { isAdding = false }
                    Button("Add") { add() }
                }
            } else {
                Button("Add rule…") { isAdding = true }
            }

            Text(footnote)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    /// A toggle writes through the whole rule, and disarms it: a rule switched
    /// off and on again should be able to fire for a condition that never
    /// stopped holding.
    private func binding(for rule: AlertRule) -> Binding<Bool> {
        Binding(
            get: { rule.isEnabled },
            set: { isEnabled in
                var updated = rule
                updated.isEnabled = isEnabled
                monitor?.ruleChanged(rule.id)
                preferences.updateAlertRule(updated)
                if isEnabled { askPermission() }
            }
        )
    }

    private func add() {
        preferences.addAlertRule(
            AlertRule(
                series: draft.series,
                comparison: draft.comparison,
                threshold: draft.entered / MetricSeriesText.entryScale(draft.series),
                duration: draft.duration
            )
        )
        isAdding = false
        askPermission()
    }

    /// Asked here and nowhere else: the first rule is the first moment this app
    /// has anything to say, and an app that asks before that is asking to be
    /// refused — a refusal the system remembers and the app cannot undo.
    private func askPermission() {
        guard let monitor else { return }
        Task { await monitor.requestPermissionIfNeeded() }
    }

    private var footnote: String {
        // Two facts a rule's own text cannot carry, and both change what the
        // user should expect: the delay is real, and a denied permission makes
        // every rule here silent without changing how any of them look.
        let lag =
            "Read from the recorded history, so an alert arrives up to a minute after the condition has held for its whole window."
        guard monitor?.permission == .denied else { return lag }
        return lag
            + " Notifications are switched off for Caliper in System Settings, so nothing here can reach you until they are back on."
    }
}
