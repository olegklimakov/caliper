import CaliperHistory
import Foundation
import Observation
import UserNotifications

/// Watches the record for the conditions the user asked about, and says so once
/// when one starts holding.
///
/// A pass a minute, not a pass a tick: the finest bucket is ten seconds and the
/// writer batches a minute, so nothing a rule can see changes faster than that.
/// The whole cost is a small indexed read per enabled rule — `buckets(for:)`
/// asks for one series over one window, never the whole slice.
@MainActor
@Observable
final class AlertMonitor {
    /// How the last authorization request went, so settings can say why an
    /// enabled rule is silent rather than leaving the user to wonder.
    enum Permission: Equatable {
        case notAsked
        case granted
        case denied
    }

    private(set) var permission: Permission = .notAsked

    private let reader: HistoryReader?
    private let preferences: Preferences
    private let centre: UNUserNotificationCenter?
    private var state = AlertState()
    private var pass: Task<Void, Never>?

    /// One pass a minute. Anything faster re-reads buckets that cannot have
    /// changed; anything slower makes "for five minutes" mean "for five to
    /// seven".
    private static let interval: TimeInterval = 60

    init(reader: HistoryReader?, preferences: Preferences, centre: UNUserNotificationCenter?) {
        self.reader = reader
        self.preferences = preferences
        self.centre = centre
    }

    func start() {
        guard pass == nil, reader != nil else { return }
        pass = Task { [weak self] in
            while !Task.isCancelled {
                await self?.evaluate()
                try? await Task.sleep(for: .seconds(Self.interval))
            }
        }
    }

    func stop() {
        pass?.cancel()
        pass = nil
    }

    /// Asked when the user enables their first rule and never at launch.
    ///
    /// An app that wants notification permission before it has anything to say
    /// is asking to be refused, and a refusal is remembered by the system —
    /// there is no second chance from inside the app.
    func requestPermissionIfNeeded() async {
        guard let centre, permission == .notAsked else { return }
        let granted = (try? await centre.requestAuthorization(options: [.alert, .sound])) ?? false
        permission = granted ? .granted : .denied
    }

    /// A rule that was edited is armed again — otherwise raising a threshold
    /// past a firing condition leaves it silent until it clears at the old one.
    func ruleChanged(_ id: UUID) {
        state.forget(id)
    }

    private func evaluate() async {
        guard let reader else { return }
        for rule in preferences.alertRules where rule.isEnabled {
            guard let samples = try? await reader.buckets(for: rule) else { continue }
            let isFiring = AlertEvaluator.isFiring(rule, over: samples, now: Date())
            guard state.shouldAnnounce(rule, isFiring: isFiring) else { continue }
            await announce(rule)
        }
    }

    private func announce(_ rule: AlertRule) async {
        guard let centre, permission == .granted else { return }
        let content = UNMutableNotificationContent()
        content.title = AlertRuleText.title(rule)
        content.body = AlertRuleText.body(rule)
        // Delivered now: a trigger of nil is immediate, and a rule that has
        // already held for its whole window is not news that keeps.
        try? await centre.add(
            UNNotificationRequest(identifier: rule.id.uuidString, content: content, trigger: nil)
        )
    }
}

/// What a rule reads as, in one place: the notification and the settings row
/// have to describe the same rule the same way, or the thing that fired and the
/// thing in the list look like two rules.
enum AlertRuleText {
    static func title(_ rule: AlertRule) -> String {
        "\(MetricSeriesText.name(rule.series)) \(rule.comparison == .above ? "over" : "under") \(threshold(rule))"
    }

    static func body(_ rule: AlertRule) -> String {
        "For the last \(DurationFormatter.brief(rule.duration))."
    }

    /// One sentence, for a settings row that has to say the whole rule.
    static func sentence(_ rule: AlertRule) -> String {
        "\(title(rule)) for \(DurationFormatter.brief(rule.duration))"
    }

    static func threshold(_ rule: AlertRule) -> String {
        MetricSeriesText.format(rule.series, rule.threshold)
    }
}

/// A series' name and unit, for the places that talk about a series rather than
/// draw one.
enum MetricSeriesText {
    static func name(_ series: MetricSeries) -> String {
        switch series {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .networkDownload: "Download"
        case .networkUpload: "Upload"
        case .diskRead: "Disk read"
        case .diskWrite: "Disk write"
        case .temperature: "Temperature"
        case .gpuUtilisation: "GPU"
        case .batteryCharge: "Battery"
        }
    }

    /// The series' own unit. The rule stores SI and unscaled; only this turns
    /// it into something a person set.
    static func format(_ series: MetricSeries, _ value: Double) -> String {
        switch series {
        case .cpu, .memory, .gpuUtilisation, .batteryCharge:
            PercentFormatter.string(value)
        case .networkDownload, .networkUpload, .diskRead, .diskWrite:
            RateFormatter.panel(value)
        case .temperature:
            TemperatureFormatter.string(value)
        }
    }

    /// What a threshold is typed in, and what one typed in reads back as: a
    /// fraction is entered as a percentage, because nobody sets an alert at
    /// "0.8".
    static func entryScale(_ series: MetricSeries) -> Double {
        switch series {
        case .cpu, .memory, .gpuUtilisation, .batteryCharge: 100
        // Bytes a second, typed as megabytes a second.
        case .networkDownload, .networkUpload, .diskRead, .diskWrite: 1_048_576
        case .temperature: 1
        }
    }

    static func entryUnit(_ series: MetricSeries) -> String {
        switch series {
        case .cpu, .memory, .gpuUtilisation, .batteryCharge: "%"
        case .networkDownload, .networkUpload, .diskRead, .diskWrite: "MB/s"
        case .temperature: "°C"
        }
    }
}
