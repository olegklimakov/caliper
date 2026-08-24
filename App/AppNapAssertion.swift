import Foundation

/// Keeps App Nap from throttling the sampling timer while its metrics are
/// actually on screen.
///
/// `.userInitiatedAllowingIdleSystemSleep` is deliberate: the machine should
/// still be free to fall asleep on its own — a monitor that keeps a laptop
/// awake to watch itself is worse than one that misses a few samples.
final class AppNapAssertion {
    private let activity: NSObjectProtocol

    init(reason: String) {
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: reason
        )
    }

    deinit {
        ProcessInfo.processInfo.endActivity(activity)
    }
}
