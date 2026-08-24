/// Physical memory in use, in bytes, split the way Activity Monitor splits it.
///
/// `app + wired + compressed` is the "memory used" figure; `cached` is
/// file-backed memory the kernel can reclaim on demand, which is why a healthy
/// machine shows almost no free memory and that is not a problem.
public struct MemorySample: Sendable, Codable, Equatable {
    public let total: UInt64
    public let app: UInt64
    public let wired: UInt64
    public let compressed: UInt64
    public let cached: UInt64
    public let free: UInt64
    public let swapUsed: UInt64
    public let swapTotal: UInt64
    /// `nil` when the kernel does not report a pressure level, so the UI can
    /// leave the field out rather than claim everything is fine.
    public let pressure: MemoryPressure?

    public var used: UInt64 { app &+ wired &+ compressed }

    /// How much of installed memory is in use, 0…1.
    ///
    /// Here rather than at each place that wants it: the menu bar gauge, the
    /// panel's bar, the combined window's row and the recorded series were all
    /// dividing `used` by `total` with their own idea of what a total of zero
    /// means.
    public var usedFraction: Double {
        total > 0 ? Double(used) / Double(total) : 0
    }

    /// What the system can still hand out. The remainder rather than
    /// `cached + free`, so that `used + available` is exactly `total`: the page
    /// counters leave a little unaccounted for, and a split that does not add
    /// up to the installed memory is a split a user cannot check.
    public var available: UInt64 { total.subtractingClamped(used) }
}

/// The kernel's own view of memory pressure, which drives when it starts
/// compressing and killing — a better signal than any percentage we compute.
public enum MemoryPressure: String, Sendable, Codable {
    case normal
    case warning
    case critical
}
