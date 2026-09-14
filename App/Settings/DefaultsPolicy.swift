import Foundation

/// Which `UserDefaults` domain this app's settings live in.
///
/// `CALIPER_DEFAULTS_SUITE` hands it a throwaway one, the way
/// `CALIPER_DISABLE_SENSORS` hands it a machine with no sensors. The first-run
/// flow can only be walked by an app that has never run before, and without
/// this the only way to walk it is over the settings of whoever is running the
/// harness.
enum DefaultsPolicy {
    static let environmentKey = "CALIPER_DEFAULTS_SUITE"

    /// Set only when a domain was asked for by name. It also answers "is this
    /// identity a throwaway" — see `Preferences.init`.
    static var suiteName: String? {
        guard let name = ProcessInfo.processInfo.environment[environmentKey], !name.isEmpty else {
            return nil
        }
        return name
    }

    static func store() -> UserDefaults {
        guard let suiteName, let suite = UserDefaults(suiteName: suiteName) else { return .standard }
        return suite
    }
}
