import Foundation
import CaliperCore
import Synchronization

/// Folds one-second snapshots into ten-second buckets and writes them in
/// batches.
///
/// A transaction per tick is a disk wakeup per tick, and ten-second buckets with
/// min/avg/max lose nothing a chart can draw while storing a sixth as many rows.
///
/// A lock rather than an actor, so the flush at quit can be synchronous:
/// `applicationWillTerminate` returns and the process dies, which is not long
/// enough for an awaited task.
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

    /// Where the folding happens, and the seam the tests drive: `SystemSnapshot`
    /// has a dozen fields and no public initialiser.
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

    /// What the settings screen's clear needs: emptying the tables while the
    /// recorder holds a filling bucket and a minute of pending rows puts part of
    /// the record straight back.
    public func discardPending() {
        state.withLock { state in
            state.open.removeAll(keepingCapacity: false)
            state.openBucket = nil
            state.pending.removeAll(keepingCapacity: false)
        }
        // And wait for what is already on its way: a batch handed to this
        // queue a moment ago would land *after* the delete.
        writeQueue.sync {}
    }

    /// Everything in memory, the filling bucket included, on the calling
    /// thread — otherwise a logout loses up to a minute of history.
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
        if let gpu = snapshot.gpuDevice {
            values[.gpuUtilisation] = gpu.utilisation
        }
        // Only where there is a battery: a desktop would otherwise record a
        // flat zero for two years and the chart would read as a machine that
        // has been dead the whole time.
        if let battery = snapshot.power?.battery {
            values[.batteryCharge] = battery.charge
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
