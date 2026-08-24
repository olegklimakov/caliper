import Foundation

/// Thin, allocation-light wrapper around `sysctlbyname`.
///
/// Every accessor returns `nil` when the key is absent so callers can degrade
/// on hardware that does not publish it (e.g. `hw.perflevel1.*` on a machine
/// with a single core cluster).
public enum Sysctl {
    public static func string(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Reads a fixed-layout value: an integer, or a C struct such as `xsw_usage`.
    public static func value<T: BitwiseCopyable>(_ name: String, as type: T.Type = T.self) -> T? {
        var buffer = [UInt8](repeating: 0, count: MemoryLayout<T>.size)
        var size = buffer.count
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0, size == MemoryLayout<T>.size else {
            return nil
        }
        return buffer.withUnsafeBytes { $0.loadUnaligned(as: T.self) }
    }
}
