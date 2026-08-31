import Darwin

/// A reused buffer for `proc_listallpids`, shared by the process sweep and
/// the card probe so neither reallocates it every tick.
struct PIDBuffer {
    private var pids: [pid_t] = []

    /// Fills the buffer and returns the valid entries.
    mutating func read() -> ArraySlice<pid_t>? {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return nil }

        // Headroom so a process spawned between the two calls does not force a
        // reallocation on the next tick.
        if pids.count < Int(count) {
            pids = [pid_t](repeating: 0, count: Int(count) + 64)
        }

        let bytes = Int32(pids.count * MemoryLayout<pid_t>.size)
        let written = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listallpids(buffer.baseAddress, bytes)
        }
        guard written > 0 else { return nil }
        return pids[0..<Int(written)]
    }
}
