import Foundation
import CaliperCore
import Synchronization

/// Folds process sweeps into thirty-second buckets and writes them in batches.
///
/// The expensive half is already paid for: the coordinator sweeps every pid and
/// throws the result away a second later, so recording it is rows in a file, not
/// new sampling work.
///
/// The same shape as `HistoryRecorder` and for the same reasons: a lock rather
/// than an actor so the flush at termination is synchronous, and one transaction
/// a minute.
public final class ProcessHistoryRecorder: Sendable {
    private let store: HistoryStore
    private let tier = ProcessTier.thirtySeconds
    /// One transaction a minute: two buckets' worth. Shared with the read
    /// side, which has to know the same number — see `ProcessTier.flushInterval`.
    private let flushInterval = ProcessTier.flushInterval
    private let writeQueue = DispatchQueue(
        label: "com.olegklimakov.caliper.processHistory",
        qos: .utility
    )

    private let state: Mutex<State>

    private struct State {
        var isEnabled: Bool
        var pinned: Set<String> = []
        var open: [String: Accumulator] = [:]
        var openBucket: Date?
        /// Names that ranked recently, and the bucket they last ranked in.
        /// What keeps a strip from being a comb; see `ProcessTier.stickiness`.
        var sticky: [String: Date] = [:]
        /// A snapshot carries the newest process sample rather than one taken
        /// on its own tick, so the same sweep arrives every second — up to
        /// thirty times when hidden — and folding it each time weights it
        /// thirtyfold.
        var lastSweep: Date?
        /// The bucket whose roster has been noted. Presence is recorded at
        /// bucket granularity, so folding six hundred names once a second
        /// would be twenty-nine parts waste.
        var rosterBucket: Date?
        var pending: [ProcessRow] = []
        var appearances: [String: ProcessAppearanceRow] = [:]
        var lastFlush = Date()
        var lastRegistryFlush = Date()
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

    /// Names recorded every bucket whatever they rank — the way to earn a
    /// strip with no ambiguous gaps in it.
    public func setPinned(_ names: Set<String>) {
        state.withLock { $0.pinned = names }
    }

    /// What the sweep has to report by name for the next bucket to be
    /// complete: the pins, plus the names still inside their sticky window.
    ///
    /// Capped, most recently ranked first. Rank churn is unbounded in
    /// principle — a machine thrashing could put a hundred names through the
    /// top ten inside one window — and a bucket's width is not allowed to
    /// follow it.
    public var watching: Set<String> {
        state.withLock { state in
            guard state.isEnabled else { return [] }
            let recent = state.sticky
                .sorted { $0.value > $1.value }
                .prefix(max(ProcessTier.watchLimit - state.pinned.count, 0))
                .map(\.key)
            return state.pinned.union(recent)
        }
    }

    /// What the delete button needs: emptying the tables while the recorder
    /// holds a bucket and a minute of pending rows puts part of the record
    /// straight back.
    public func discardPending() {
        state.withLock { Self.discard(&$0) }
        // And wait for what is already on its way: a batch handed to this
        // queue a moment ago would land *after* the delete.
        writeQueue.sync {}
    }

    private static func discard(_ state: inout State) {
        state.open.removeAll(keepingCapacity: false)
        state.openBucket = nil
        state.lastSweep = nil
        state.rosterBucket = nil
        state.sticky.removeAll(keepingCapacity: false)
        state.pending.removeAll(keepingCapacity: false)
        state.appearances.removeAll(keepingCapacity: false)
    }

    /// The sweep rather than the whole snapshot: it is all this records.
    public func record(_ processes: ProcessesSample) {
        let batch = state.withLock { state -> Batch? in
            guard state.isEnabled else { return nil }
            guard state.lastSweep != processes.sampledAt else { return nil }
            state.lastSweep = processes.sampledAt

            let bucket = tier.bucketStart(of: processes.sampledAt)
            if let openBucket = state.openBucket, openBucket != bucket {
                Self.close(bucket: openBucket, in: &state)
            }
            state.openBucket = bucket

            Self.fold(processes, into: &state)
            if state.rosterBucket != bucket {
                state.rosterBucket = bucket
                Self.note(processes.roster, at: processes.sampledAt, in: &state)
            }

            let registryIsDue =
                processes.sampledAt.timeIntervalSince(state.lastRegistryFlush)
                >= ProcessTier.registryFlushInterval
            let rowsAreDue =
                processes.sampledAt.timeIntervalSince(state.lastFlush) >= flushInterval

            guard rowsAreDue || registryIsDue else { return nil }
            var batch = Batch(rows: [], appearances: [])
            if rowsAreDue, !state.pending.isEmpty {
                state.lastFlush = processes.sampledAt
                batch.rows = Self.takeRows(&state)
            }
            if registryIsDue, !state.appearances.isEmpty {
                state.lastRegistryFlush = processes.sampledAt
                batch.appearances = Self.takeAppearances(&state)
            }
            return batch.rows.isEmpty && batch.appearances.isEmpty ? nil : batch
        }

        guard let batch else { return }
        writeQueue.async { [store, tier] in
            try? store.write(processes: batch.rows, tier: tier)
            try? store.write(appearances: batch.appearances)
        }
    }

    /// Writes everything held in memory, including the bucket still filling, on
    /// the calling thread — `applicationWillTerminate` returns and the process
    /// dies, which is not long enough for an awaited task to finish.
    public func flushNow() throws {
        let batch = state.withLock { state -> Batch in
            guard state.isEnabled else { return Batch(rows: [], appearances: []) }
            if let openBucket = state.openBucket {
                Self.close(bucket: openBucket, in: &state)
                state.openBucket = nil
            }
            state.lastFlush = Date()
            state.lastRegistryFlush = state.lastFlush
            return Batch(rows: Self.takeRows(&state), appearances: Self.takeAppearances(&state))
        }
        try store.write(processes: batch.rows, tier: tier)
        try store.write(appearances: batch.appearances)
    }

    private struct Batch {
        var rows: [ProcessRow]
        var appearances: [ProcessAppearanceRow]
    }

    private static func takeRows(_ state: inout State) -> [ProcessRow] {
        defer { state.pending.removeAll(keepingCapacity: true) }
        return state.pending
    }

    private static func takeAppearances(_ state: inout State) -> [ProcessAppearanceRow] {
        defer { state.appearances.removeAll(keepingCapacity: true) }
        return Array(state.appearances.values)
    }

    /// Sums each name's pids over one sweep, then folds one reading per name.
    ///
    /// A pid counts once however many lists it is in; a *name* sums however
    /// many pids carry it. Forty processes called "Google Chrome Helper" are
    /// one program's worth of work, and taking only the first of them was
    /// under-reporting every browser on the machine.
    private static func fold(_ processes: ProcessesSample, into state: inout State) {
        var seen: Set<pid_t> = []
        var readings: [String: Reading] = [:]
        for sample in processes.topByCPU + processes.topByMemory + processes.topByDisk
            + processes.topByPower + processes.watched
        where seen.insert(sample.pid).inserted {
            readings[sample.name, default: Reading()].add(sample, interval: processes.interval)
        }
        for (name, reading) in readings {
            state.open[name, default: Accumulator()].add(reading)
        }
    }

    /// Folds one sweep's roster into the per-name record.
    private static func note(_ roster: [ProcessIdentity], at moment: Date, in state: inout State) {
        let day = ProcessAppearanceRow.day(of: moment)
        let hour = ProcessAppearanceRow.hourBit(of: moment)
        for identity in roster {
            state.appearances[identity.name, default: ProcessAppearanceRow(identity: identity, at: moment)]
                .observe(identity: identity, at: moment, day: day, hour: hour)
        }
    }

    /// Top ten by CPU, by footprint and by energy, plus every name held by a
    /// pin or by its sticky window.
    ///
    /// Not by disk: that question is answered by the disk series itself, and a
    /// fourth ranking would cost rows for a fact already stored. The rate is
    /// still kept for whoever makes the list.
    private static func close(bucket start: Date, in state: inout State) {
        var rows = state.open.map { name, accumulator in
            accumulator.row(name: name, timestamp: start)
        }
        state.open.removeAll(keepingCapacity: true)

        // Zeroes never rank. Most of the machine draws no measurable power and
        // touches no disk, so a ranking that admitted them would fill ten rows
        // a bucket with an arbitrary pick from the tie — the rule the sweep's
        // own power and disk lists already follow.
        var ranked: Set<String> = []
        func rank(by value: (ProcessRow) -> Int) {
            for row in rows.filter({ value($0) > 0 })
                .sorted(by: { value($0) > value($1) })
                .prefix(ProcessTier.topCount)
            {
                ranked.insert(row.name)
            }
        }
        rank(by: \.cpuPermille)
        rank(by: \.footprintMB)
        rank(by: \.energyMJ)

        // The sticky window is measured from the last bucket a name ranked in,
        // so it has to be read before this bucket's ranks are written into it.
        let held = start.addingTimeInterval(-ProcessTier.stickiness)
        var reasons: [String: ProcessKeepReason] = [:]
        for row in rows {
            if ranked.contains(row.name) {
                reasons[row.name] = .ranked
            } else if let lastRanked = state.sticky[row.name], lastRanked >= held {
                reasons[row.name] = .sticky
            }
            if state.pinned.contains(row.name) {
                reasons[row.name] = .pinned
            }
        }

        // Tracked for every name that ranked, pinned ones included: a pin can
        // be taken off, and the window it leaves behind is the honest one.
        for name in ranked {
            state.sticky[name] = start
        }
        state.sticky = state.sticky.filter { $0.value >= held }

        for index in rows.indices {
            rows[index].keep = reasons[rows[index].name] ?? .ranked
        }
        state.pending.append(contentsOf: rows.filter { reasons[$0.name] != nil })
    }

    /// One name's share of one sweep: its pids summed.
    struct Reading {
        private(set) var pids = 0
        private(set) var cpu = 0.0
        private(set) var footprint: UInt64 = 0
        private(set) var diskRate = 0.0
        /// Joules. `power` is the `ri_energy_nj` delta divided by the sweep's
        /// own window, so multiplying it back by that window recovers the
        /// delta exactly — including across a sleep, which the window already
        /// measured.
        private(set) var energy = 0.0

        mutating func add(_ sample: ProcessSample, interval: TimeInterval) {
            guard sample.cpu.isFinite, sample.diskRate.isFinite else { return }
            pids += 1
            cpu += sample.cpu
            footprint += sample.memoryFootprint
            diskRate += sample.diskRate
            if sample.power.isFinite {
                energy += sample.power * interval
            }
        }
    }

    /// Running mean CPU, peak footprint, mean disk rate and total energy over
    /// one bucket. Peak for memory because the question is what a process took
    /// at worst; means for the rates, which say how busy the bucket was
    /// overall; a total for energy, which is the only one of the four that adds
    /// up.
    struct Accumulator {
        private var cpuTotal = 0.0
        private var diskTotal = 0.0
        private var energyTotal = 0.0
        private var peakFootprint: UInt64 = 0
        private var count = 0

        mutating func add(_ reading: Reading) {
            guard reading.pids > 0 else { return }
            cpuTotal += reading.cpu
            diskTotal += reading.diskRate
            energyTotal += reading.energy
            peakFootprint = Swift.max(peakFootprint, reading.footprint)
            count += 1
        }

        /// A process whose sweeps were all rejected as non-finite still has a
        /// row: it was in the top ten, and zero says so more honestly than
        /// dropping it.
        func row(name: String, timestamp: Date) -> ProcessRow {
            let readings = Swift.max(count, 1)
            return ProcessRow(
                name: name,
                timestamp: timestamp,
                cpuPermille: Int((cpuTotal / Double(readings) * 1000).rounded()),
                footprintMB: Int(peakFootprint / 1_048_576),
                diskKBps: Int((diskTotal / Double(readings) / 1024).rounded()),
                energyMJ: Int((energyTotal * 1000).rounded()),
                keep: .ranked,
                count: readings
            )
        }
    }
}
