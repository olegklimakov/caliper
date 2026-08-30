import Foundation

/// Whether the accelerator sweep may run.
///
/// The GPU read is public IOKit, but the properties it reads are undocumented,
/// and PRD §6 wants degradation proven rather than assumed. The environment
/// variable makes "the accelerator refused" reproducible on any machine —
/// there is no supported way to make real hardware fail on demand.
enum GPUPolicy {
    static let environmentKey = "CALIPER_DISABLE_GPU"

    static var allowsAcceleratorSweep: Bool {
        ProcessInfo.processInfo.environment[environmentKey] == nil
    }
}
