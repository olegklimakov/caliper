import Foundation
import CaliperCore
import Synchronization

/// Folds one-second snapshots into ten-second buckets and writes them in
/// batches.
///
/// Two reasons not to write every tick. A transaction per second is a disk
/// wakeup per second, which is exactly the cost this app promises not to have.
/// And ten-second buckets with min/avg/max lose nothing a chart can draw while
/// storing a sixth as many rows.
///
/// A lock rather than an actor, so the flush that runs when the app is quitting
/// can be synchronous: `applicationWillTerminate` returns and the process dies,
/// which is not long enough for an awaited task to finish.
public final class HistoryRecorder: Sendable {
    private let store: HistoryStore
    private let tier = HistoryTier.tenSeconds
    /// One transaction a minute: six buckets' worth.
    private let flushInterval: TimeInterval = 60
    /// Batched writes go here, so a transaction never lands on whichever
    /// thread happened to deliver a snapshot.
    private let writeQueue = DispatchQueue(
        label: "com.olegklimakov.caliper.history",
        qos: .utility
    )

    private let state = Mutex(State())

    private struct State {
        var open: [MetricSeries: Accumulator] = [:]
        var openBucket: Date?
        var pending: [HistorySample] = []
        var lastFlush = Date()
    }

    public init(store: HistoryStore) {
        self.store = store
    }

    public func record(_ snapshot: SystemSnapshot) {
        record(Self.values(of: snapshot), at: snapshot.timestamp)
    }

    /// The numbers, without the snapshot they came out of.
    ///
    /// Where the folding actually happens, and the seam the tests drive:
    /// `SystemSnapshot` has a dozen fields and no public initialiser, so a test
    /// that had to build one to prove a bucket closes correctly would be a test
    /// about the wrong thing.
    func record(_ values: [MetricSeries: Double], at timestamp: Date) {
        let batch = state.withLock { state -> [HistorySample]? in
            let bucket = tier.bucketStart(of: timestamp)
            if let openBucket = state.openBucket, openBucket != bucket {
                Self.close(bucket: openBucket, in: &state)
            }
            state.openBucket = bucket

            for (series, value) in values {
                state.open[series, default: Accumulator()].add(value)
            }

            guard timestamp.timeIntervalSince(state.lastFlush) >= flushInterval,
                !state.pending.isEmpty
            else { return nil }

            state.lastFlush = timestamp
            defer { state.pending.removeAll(keepingCapacity: true) }
            return state.pending
        }

        guard let batch else { return }
        writeQueue.async { [store, tier] in
            try? store.write(batch, tier: tier)
        }
    }

    /// Throws away everything held in memory without writing it.
    ///
    /// What the settings screen's clear needs: emptying the tables while the
    /// recorder still holds the bucket it is filling and up to a minute of
    /// pending rows would put part of the record straight back.
    public func discardPending() {
        state.withLock { state in
            state.open.removeAll(keepingCapacity: false)
            state.openBucket = nil
            state.pending.removeAll(keepingCapacity: false)
        }
        // And wait for whatever is already on its way to the store. Clearing
        // the memory alone leaves a batch handed to this queue a moment ago
        // still in flight, and it would land *after* the delete — which is the
        // one thing this method promises does not happen.
        writeQueue.sync {}
    }

    /// Writes everything held in memory, including the bucket still filling,
    /// on the calling thread.
    ///
    /// The alternative is losing up to a minute of history every time someone
    /// logs out.
    public func flushNow() throws {
        let batch = state.withLock { state -> [HistorySample] in
            if let openBucket = state.openBucket {
                Self.close(bucket: openBucket, in: &state)
                state.openBucket = nil
            }
            defer { state.pending.removeAll(keepingCapacity: true) }
            state.lastFlush = Date()
            return state.pending
        }
        try store.write(batch, tier: tier)
    }

    private static func close(bucket start: Date, in state: inout State) {
        for (series, accumulator) in state.open {
            guard let aggregate = accumulator.aggregate else { continue }
            state.pending.append(
                HistorySample(series: series, timestamp: start, aggregate: aggregate)
            )
        }
        state.open.removeAll(keepingCapacity: true)
    }

    /// The aggregate numbers worth keeping for years, pulled out of a snapshot.
    static func values(of snapshot: SystemSnapshot) -> [MetricSeries: Double] {
        var values: [MetricSeries: Double] = [:]
        if let cpu = snapshot.cpu {
            values[.cpu] = cpu.total
        }
        if let memory = snapshot.memory, memory.total > 0 {
            values[.memory] = Double(memory.used) / Double(memory.total)
        }
        if let network = snapshot.network {
            values[.networkDownload] = network.downloadRate
            values[.networkUpload] = network.uploadRate
        }
        if let disk = snapshot.diskActivity {
            values[.diskRead] = disk.readRate
            values[.diskWrite] = disk.writeRate
        }
        if let peak = snapshot.sensors?.peakTemperature {
            values[.temperature] = peak
        }
        return values
    }
}

/// Running min, mean and max over a bucket, without keeping the samples.
struct Accumulator {
    private var minimum = Double.infinity
    private var maximum = -Double.infinity
    private var total = 0.0
    private var count = 0

    mutating func add(_ value: Double) {
        guard value.isFinite else { return }
        minimum = Swift.min(minimum, value)
        maximum = Swift.max(maximum, value)
        total += value
        count += 1
    }

    var aggregate: Aggregate? {
        guard count > 0 else { return nil }
        return Aggregate(
            minimum: minimum,
            average: total / Double(count),
            maximum: maximum,
            count: count
        )
    }
}
