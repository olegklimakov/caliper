import Foundation

/// Whether the app is allowed to touch the private sensor interfaces.
///
/// Setting `CALIPER_DISABLE_SENSORS` turns them off. It exists to make the
/// degradation PRD §6 asks for verifiable on any machine — run the app with it
/// set and the Sensors feature is hidden rather than showing zeros — without
/// having to find hardware whose sensors actually fail.
enum SensorPolicy {
    static let environmentKey = "CALIPER_DISABLE_SENSORS"

    static var allowsPrivateInterfaces: Bool {
        ProcessInfo.processInfo.environment[environmentKey] == nil
    }
}
