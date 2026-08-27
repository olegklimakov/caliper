import Darwin

/// One process's resource counters, from `proc_pid_rusage`.
///
/// Works for any pid without extra privileges, which is why it — and not
/// `task_info` — backs both the process list and the app's own metrics.
enum ResourceUsage {
    /// `proc_pid_rusage` reports CPU time in mach time units, not nanoseconds.
    /// They are the same thing on Intel, which is why the difference is easy to
    /// miss; on Apple Silicon a tick is 125/3 ns, so skipping this conversion
    /// under-reports every process by a factor of forty-one.
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    struct Counters {
        /// Nanoseconds of CPU time since the process started.
        let cpuTime: UInt64
        /// What the memory system charges the process, matching the
        /// "Memory" column in Activity Monitor.
        let physicalFootprint: UInt64
        /// Bytes this process has read from and written to storage since it
        /// started — the same counters Activity Monitor's Disk tab shows.
        let bytesRead: UInt64
        let bytesWritten: UInt64
    }

    static func counters(for pid: pid_t) -> Counters? {
        var info = rusage_info_current()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, rebound)
            }
        }
        guard result == 0 else { return nil }

        let ticks = info.ri_user_time &+ info.ri_system_time
        return Counters(
            cpuTime: ticks * UInt64(timebase.numer) / UInt64(timebase.denom),
            physicalFootprint: info.ri_phys_footprint,
            bytesRead: info.ri_diskio_bytesread,
            bytesWritten: info.ri_diskio_byteswritten
        )
    }

    /// `proc_pidpath` gives the real executable name where `proc_name`
    /// truncates at sixteen characters, but the path is unreadable for another
    /// user's processes — and a runaway root process is the one worth seeing, so
    /// a truncated name beats dropping it.
    static func name(for pid: pid_t) -> String {
        // `PROC_PIDPATHINFO_MAXSIZE` is a macro Swift does not import.
        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        if pathLength > 0 {
            let path = CString.string(pathBuffer, length: Int(pathLength))
            if let executable = path.split(separator: "/").last {
                return String(executable)
            }
        }

        var nameBuffer = [CChar](repeating: 0, count: Int(MAXCOMLEN) * 2 + 1)
        let nameLength = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
        if nameLength > 0 {
            return CString.string(nameBuffer, length: Int(nameLength))
        }

        return "pid \(pid)"
    }
}
