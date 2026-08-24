import Darwin

/// Memory usage from `host_statistics64`, swap from `vm.swapusage`.
///
/// Stateless: these are levels, not counters, so there is no baseline to keep.
struct MemorySampler {
    func sample(totalMemory: UInt64) -> MemorySample? {
        guard let statistics = Self.readVMStatistics() else { return nil }

        // `vm_kernel_page_size` is a mutable global and so off limits under
        // strict concurrency; `getpagesize()` reports the same value and needs
        // no fallback constant that would be wrong on some other machine.
        let pageSize = UInt64(getpagesize())
        func bytes(_ pages: some FixedWidthInteger) -> UInt64 { UInt64(pages) &* pageSize }

        // Activity Monitor's split: app memory is anonymous memory minus what is
        // purgeable, and purgeable pages count as reclaimable cache instead.
        let purgeable = bytes(statistics.purgeable_count)
        let app = bytes(statistics.internal_page_count).subtractingClamped(purgeable)
        let swap = Sysctl.value("vm.swapusage", as: xsw_usage.self)

        return MemorySample(
            total: totalMemory,
            app: app,
            wired: bytes(statistics.wire_count),
            compressed: bytes(statistics.compressor_page_count),
            cached: bytes(statistics.external_page_count) &+ purgeable,
            // Speculative pages are already read ahead for someone, so the
            // genuinely unused remainder is what is left after them.
            free: bytes(statistics.free_count).subtractingClamped(bytes(statistics.speculative_count)),
            swapUsed: swap?.xsu_used ?? 0,
            swapTotal: swap?.xsu_total ?? 0,
            pressure: Self.readPressure()
        )
    }

    private static func readVMStatistics() -> vm_statistics64_data_t? {
        var statistics = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride
        )
        let result = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        return result == KERN_SUCCESS ? statistics : nil
    }

    /// `nil` when the kernel does not answer: reporting "normal" for an
    /// unreadable pressure level would be showing garbage, which the panel is
    /// meant to hide instead.
    private static func readPressure() -> MemoryPressure? {
        switch Sysctl.value("kern.memorystatus_vm_pressure_level", as: Int32.self) {
        case 1: .normal
        case 2: .warning
        case 4: .critical
        default: nil
        }
    }
}
