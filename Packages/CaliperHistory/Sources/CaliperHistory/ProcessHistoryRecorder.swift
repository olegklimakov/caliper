import Foundation
import CaliperCore
import Synchronization

/// Folds process sweeps into thirty-second buckets and writes them in batches.
///
/// The expensive half of "what was running then" is already paid for: the
/// coordinator sweeps every pid — a syscall each — and keeps the top ten by
/// CPU, footprint and disk, then throws the result away a second later.
/// Recording it is rows in a file, not new sampling work.
///
/// The same shape as `HistoryRecorder`, and for the same reasons: a lock rather
/// than an actor so the flush at termination is synchronous, and one
/// transaction a minute rather than one a tick.
public final class ProcessHistoryRecorder: Sendable {
    private let store: HistoryStore
    private let tier = ProcessTier.thirtySeconds
    /// One transaction a minute: two buckets' worth.
    private let flushInterval: TimeInterval = 60
    private let writeQueue = DispatchQueue(
        label: "com.olegklimakov.caliper.processHistory",
        qos: .utility
    )

    private let state: Mutex<State>

    private struct State {
        var isEnabled: Bool
        var open: [String: Accumulator] = [:]
        var openBucket: Date?
        /// The sweep last folded in. A snapshot carries the newest process
        /// sample rather than one taken on its own tick, so the same sweep
        /// arrives again every second — up to thirty times when the app is
        /// hidden — and folding it each time would weight it thirtyfold.
        var lastSweep: Date?
        var pending: [ProcessRow] = []
        var lastFlush = Date()
    }

    public init(store: HistoryStore, isEnabled: Bool) {
        self.store = store
        state = Mutex(State(isEnabled: isEnabled))
    }

    /// Turns recording on or off, dropping whatever was accumulating when it
    /// goes off — a half-written bucket from before the switch is not something
    /// the user agreed to keep.
    public func setEnabled(_ isEnabled: Bool) {
        state.withLock { state in
            state.isEnabled = isEnabled
            guard !isEnabled else { return }
            Self.discard(&state)
        }
    }

    /// Throws away everything held in memory without writing it.
    ///
    /// What the delete button needs: emptying the tables while the recorder
    /// still holds a bucket and up to a minute of pending rows would put part
    /// of the record straight back moments later.
    public func discardPending() {
        state.withLock { Self.discard(&$0) }
        // And wait for whatever is already on its way to the store: a batch
        // handed to this queue a moment ago would otherwise land *after* the
        // delete.
        writeQueue.sync {}
    }

    private static func discard(_ state: inout State) {
        state.open.removeAll(keepingCapacity: false)
        state.openBucket = nil
        state.lastSweep = nil
        state.pending.removeAll(keepingCapacity: false)
    }

    /// Takes the process sweep rather than the whole snapshot: it is all this
    /// records, and a caller holding a snapshot with no processes in it has
    /// nothing to hand over.
    public func record(_ processes: ProcessesSample) {
        let batch = state.withLock { state -> [ProcessRow]? in
            guard state.isEnabled else { return nil }
            guard state.lastSweep != processes.sampledAt else { return nil }
            state.lastSweep = processes.sampledAt

            let bucket = tier.bucketStart(of: processes.sampledAt)
            if let openBucket = state.openBucket, openBucket != bucket {
                Self.close(bucket: openBucket, in: &state)
            }
            state.openBucket = bucket

            // Every process the sampler thought worth naming, each counted once
            // however many of the three lists it appears in. Which of them the
            // bucket keeps is decided when it closes, over the whole bucket
            // rather than over whichever sweep happened to be last.
            var seen: Set<String> = []
            for sample in processes.topByCPU + processes.topByMemory + processes.topByDisk
            where seen.insert(sample.name).inserted {
                state.open[sample.name, default: Accumulator()].add(sample)
            }

            guard processes.sampledAt.timeIntervalSince(state.lastFlush) >= flushInterval,
                !state.pending.isEmpty
            else { return nil }

            state.lastFlush = processes.sampledAt
            defer { state.pending.removeAll(keepingCapacity: true) }
            return state.pending
        }

        guard let batch else { return }
        writeQueue.async { [store, tier] in
            try? store.write(processes: batch, tier: tier)
        }
    }

    /// Writes everything held in memory, including the bucket still filling, on
    /// the calling thread — `applicationWillTerminate` returns and the process
    /// dies, which is not long enough for an awaited task to finish.
    public func flushNow() throws {
        let batch = state.withLock { state -> [ProcessRow] in
            guard state.isEnabled else { return [] }
            if let openBucket = state.openBucket {
                Self.close(bucket: openBucket, in: &state)
                state.openBucket = nil
            }
            defer { state.pending.removeAll(keepingCapacity: true) }
            state.lastFlush = Date()
            return state.pending
        }
        try store.write(processes: batch, tier: tier)
    }

    /// Ranks what the bucket saw and keeps the heaviest of it.
    ///
    /// Top ten by CPU unioned with top ten by footprint. Not by disk: a process
    /// that only ever touched the disk is answered by the disk series itself,
    /// and a third ranking would half again the rows for a question the readout
    /// does not ask. Its rate is still stored for the processes that do make
    /// the list.
    private static func close(bucket start: Date, in state: inout State) {
        let totals = state.open.map { name, accumulator in
            accumulator.row(name: name, timestamp: start)
        }
        var kept: [String: ProcessRow] = [:]
        for row in totals.sorted(by: { $0.cpuPermille > $1.cpuPermille }).prefix(ProcessTier.topCount) {
            kept[row.name] = row
        }
        for row in totals.sorted(by: { $0.footprintMB > $1.footprintMB }).prefix(ProcessTier.topCount) {
            kept[row.name] = row
        }
        state.pending.append(contentsOf: kept.values)
        state.open.removeAll(keepingCapacity: true)
    }

    /// Running mean CPU, peak footprint and mean disk rate over one bucket, for
    /// one process.
    ///
    /// Peak footprint rather than mean because the question asked of a memory
    /// history is what a process took at worst; means for the two rates because
    /// what a bucket says about them is how busy it was overall.
    struct Accumulator {
        private var cpuTotal = 0.0
        private var diskTotal = 0.0
        private var peakFootprint: UInt64 = 0
        private var count = 0

        mutating func add(_ sample: ProcessSample) {
            guard sample.cpu.isFinite, sample.diskRate.isFinite else { return }
            cpuTotal += sample.cpu
            diskTotal += sample.diskRate
            peakFootprint = Swift.max(peakFootprint, sample.memoryFootprint)
            count += 1
        }

        /// A process seen only in sweeps that were all rejected as
        /// non-finite still has a row: it was in the top ten, and a footprint
        /// of zero says so more honestly than dropping it would.
        func row(name: String, timestamp: Date) -> ProcessRow {
            let readings = Swift.max(count, 1)
            return ProcessRow(
                name: name,
                timestamp: timestamp,
                cpuPermille: Int((cpuTotal / Double(readings) * 1000).rounded()),
                footprintMB: Int(peakFootprint / 1_048_576),
                diskKBps: Int((diskTotal / Double(readings) / 1024).rounded()),
                count: readings
            )
        }
    }
}
