import Darwin

/// One process's resource counters, from `proc_pid_rusage`.
///
/// Works for any pid without extra privileges, which is why it — and not
/// `task_info` — backs both the process list and the app's own metrics.
enum ResourceUsage {
    /// `proc_pid_rusage` reports CPU time — every QoS bucket included — in
    /// mach time units, not nanoseconds. They are the same thing on Intel,
    /// which is why the difference is easy to miss; on Apple Silicon a tick is
    /// 125/3 ns, so skipping this conversion under-reports every process by a
    /// factor of forty-one.
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    private static func nanoseconds(fromTicks ticks: UInt64) -> UInt64 {
        ticks * UInt64(timebase.numer) / UInt64(timebase.denom)
    }

    /// CPU time per QoS tier, in nanoseconds. All-zero means the process does
    /// not report QoS accounting at all; `ProcessSample.qos` carries what that
    /// implies.
    struct QoSTime {
        let userInteractive: UInt64
        let userInitiated: UInt64
        let defaultTier: UInt64
        let legacy: UInt64
        let utility: UInt64
        let background: UInt64
        let maintenance: UInt64

        var total: UInt64 {
            userInteractive &+ userInitiated &+ defaultTier &+ legacy
                &+ utility &+ background &+ maintenance
        }
    }

    struct Counters {
        /// Nanoseconds of CPU time since the process started.
        let cpuTime: UInt64
        /// What the memory system charges the process, matching the
        /// "Memory" column in Activity Monitor.
        let physicalFootprint: UInt64
        /// The most `physicalFootprint` has ever read for this process.
        let lifetimeMaxFootprint: UInt64
        /// Bytes this process has read from and written to storage since it
        /// started — the same counters Activity Monitor's Disk tab shows.
        let bytesRead: UInt64
        let bytesWritten: UInt64
        /// Nanojoules the SoC's own accounting charges this process; what that
        /// number does and does not count is documented on
        /// `ProcessSample.power`.
        let energy: UInt64
        /// The share of `energy` spent on the performance clusters.
        let pEnergy: UInt64
        let cycles: UInt64
        /// Cycles retired on the performance clusters.
        let pCycles: UInt64
        let instructions: UInt64
        let qosTime: QoSTime
        /// Times the package was pulled out of idle for this process.
        let idleWakeups: UInt64
        let interruptWakeups: UInt64
        /// `ri_proc_start_abstime`, kept in raw mach absolute units: it is an
        /// identity token for detecting pid reuse, compared for equality and
        /// never displayed, so converting it would only invite arithmetic on
        /// it.
        let startTime: UInt64
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
            cpuTime: nanoseconds(fromTicks: ticks),
            physicalFootprint: info.ri_phys_footprint,
            lifetimeMaxFootprint: info.ri_lifetime_max_phys_footprint,
            bytesRead: info.ri_diskio_bytesread,
            bytesWritten: info.ri_diskio_byteswritten,
            energy: info.ri_energy_nj,
            pEnergy: info.ri_penergy_nj,
            cycles: info.ri_cycles,
            pCycles: info.ri_pcycles,
            instructions: info.ri_instructions,
            qosTime: QoSTime(
                userInteractive: nanoseconds(fromTicks: info.ri_cpu_time_qos_user_interactive),
                userInitiated: nanoseconds(fromTicks: info.ri_cpu_time_qos_user_initiated),
                defaultTier: nanoseconds(fromTicks: info.ri_cpu_time_qos_default),
                legacy: nanoseconds(fromTicks: info.ri_cpu_time_qos_legacy),
                utility: nanoseconds(fromTicks: info.ri_cpu_time_qos_utility),
                background: nanoseconds(fromTicks: info.ri_cpu_time_qos_background),
                maintenance: nanoseconds(fromTicks: info.ri_cpu_time_qos_maintenance)
            ),
            idleWakeups: info.ri_pkg_idle_wkups,
            interruptWakeups: info.ri_interrupt_wkups,
            startTime: info.ri_proc_start_abstime
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
