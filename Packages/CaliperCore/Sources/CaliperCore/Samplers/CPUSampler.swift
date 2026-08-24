import Darwin

/// Per-core CPU load from `host_processor_info` tick counters.
///
/// The kernel reports cumulative ticks, so load is the difference between two
/// readings: the first tick after launch or after a wake only seeds the
/// baseline and produces nothing.
struct CPUSampler {
    private var previous: [CoreTicks] = []

    struct CoreTicks: Equatable {
        var user: UInt64
        var system: UInt64
        var idle: UInt64
        var nice: UInt64

        var busy: UInt64 { user &+ system &+ nice }
        var all: UInt64 { busy &+ idle }
    }

    mutating func sample(clusters: [HostInfo.CoreCluster]) -> CPUSample? {
        guard let current = Self.readCoreTicks() else { return nil }
        defer { previous = current }

        // A changed core count means the previous reading describes a different
        // machine state; re-seed rather than report nonsense.
        guard previous.count == current.count, !current.isEmpty else { return nil }

        var coreBusy = [Double](repeating: 0, count: current.count)
        var busyDeltas = [UInt64](repeating: 0, count: current.count)
        var totalDeltas = [UInt64](repeating: 0, count: current.count)

        for index in current.indices {
            let busy = current[index].busy.subtractingClamped(previous[index].busy)
            let all = current[index].all.subtractingClamped(previous[index].all)
            busyDeltas[index] = busy
            totalDeltas[index] = all
            coreBusy[index] = all > 0 ? Double(busy) / Double(all) : 0
        }

        return CPUSample(
            total: Self.fraction(busy: busyDeltas.reduce(0, &+), total: totalDeltas.reduce(0, &+)),
            cores: coreBusy,
            clusters: clusters.map { cluster in
                let indices = cluster.coreIndices.filter { current.indices.contains($0) }
                return Self.fraction(
                    busy: indices.reduce(0) { $0 &+ busyDeltas[$1] },
                    total: indices.reduce(0) { $0 &+ totalDeltas[$1] }
                )
            },
            loadAverage: Self.readLoadAverage()
        )
    }

    /// Drops the baseline so the next sample starts a fresh interval, used after
    /// waking from sleep where the counters span hours of suspended time.
    mutating func resetBaseline() {
        previous = []
    }

    private static func fraction(busy: UInt64, total: UInt64) -> Double {
        total > 0 ? Double(busy) / Double(total) : 0
    }

    private static func readCoreTicks() -> [CoreTicks]? {
        var coreCount = natural_t(0)
        var info: processor_info_array_t?
        var infoCount = mach_msg_type_number_t(0)

        guard
            host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &coreCount, &info, &infoCount)
                == KERN_SUCCESS,
            let info
        else { return nil }
        defer {
            // The kernel allocates this out-of-line; leaking it would grow the
            // process every tick.
            vm_deallocate(
                mach_task_self_,
                vm_address_t(UInt(bitPattern: info)),
                vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
            )
        }

        let states = Int(CPU_STATE_MAX)
        var ticks: [CoreTicks] = []
        ticks.reserveCapacity(Int(coreCount))
        for core in 0..<Int(coreCount) {
            let base = core * states
            ticks.append(
                CoreTicks(
                    user: counter(info[base + Int(CPU_STATE_USER)]),
                    system: counter(info[base + Int(CPU_STATE_SYSTEM)]),
                    idle: counter(info[base + Int(CPU_STATE_IDLE)]),
                    nice: counter(info[base + Int(CPU_STATE_NICE)])
                )
            )
        }
        return ticks
    }

    /// Tick counters are unsigned, but `processor_info` hands them over in a
    /// signed array.
    private static func counter(_ value: integer_t) -> UInt64 {
        UInt64(UInt32(bitPattern: value))
    }

    private static func readLoadAverage() -> CPUSample.LoadAverage {
        var values = [Double](repeating: 0, count: 3)
        guard getloadavg(&values, 3) == 3 else {
            return CPUSample.LoadAverage(oneMinute: 0, fiveMinutes: 0, fifteenMinutes: 0)
        }
        return CPUSample.LoadAverage(
            oneMinute: values[0],
            fiveMinutes: values[1],
            fifteenMinutes: values[2]
        )
    }
}
