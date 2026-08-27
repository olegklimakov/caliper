import Foundation

/// The series the history keeps: a short, fixed list of *aggregate* numbers.
/// Per-core loads and per-process rows belong to the live panels — recording
/// them for two years would multiply the store by the width of the machine.
public enum MetricSeries: String, Sendable, CaseIterable, Codable {
    /// Busy fraction across all cores, 0…1.
    case cpu
    /// Used memory as a fraction of installed, 0…1.
    case memory
    /// Bytes per second.
    case networkDownload
    case networkUpload
    case diskRead
    case diskWrite
    /// Hottest real sensor, in degrees Celsius.
    case temperature
}

/// How coarse a stored bucket is.
///
/// Four tiers, each an exact multiple of the one below, so a coarser bucket is
/// always the rollup of a whole number of finer ones — no bucket ever spans a
/// boundary and needs splitting.
public enum HistoryTier: String, Sendable, CaseIterable, Codable {
    case tenSeconds
    case minute
    case tenMinutes
    case hour

    public var seconds: Int {
        switch self {
        case .tenSeconds: 10
        case .minute: 60
        case .tenMinutes: 600
        case .hour: 3600
        }
    }

    /// Fine detail is only interesting while it is recent: nobody asks what
    /// last March did second by second, but the last day is exactly what you
    /// want after something went wrong.
    public var retention: TimeInterval {
        switch self {
        case .tenSeconds: 24 * 3600
        case .minute: 7 * 24 * 3600
        case .tenMinutes: 90 * 24 * 3600
        case .hour: 2 * 365 * 24 * 3600
        }
    }

    /// The tier this one is rolled up from, or `nil` for the finest.
    public var source: HistoryTier? {
        switch self {
        case .tenSeconds: nil
        case .minute: .tenSeconds
        case .tenMinutes: .minute
        case .hour: .tenMinutes
        }
    }

    /// How wide a bucket is, as a reader writes it.
    public var label: String {
        switch self {
        case .tenSeconds: "10 s"
        case .minute: "1 min"
        case .tenMinutes: "10 min"
        case .hour: "1 h"
        }
    }

    /// Aligned to absolute time, not to when the app started, so two runs line
    /// up and a reader can find a moment's row by arithmetic.
    public func bucketStart(of date: Date) -> Date {
        CaliperHistory.bucketStart(of: date, width: seconds)
    }

    var tableName: String {
        switch self {
        case .tenSeconds: "samples_10s"
        case .minute: "samples_1m"
        case .tenMinutes: "samples_10m"
        case .hour: "samples_1h"
        }
    }
}

/// One bucket of one series. Minimum and maximum alongside the average because
/// an average hides what a monitor is for: 20 % with a thirty-second spike to
/// 100 % is a different machine from a flat 20 %.
public struct Aggregate: Sendable, Codable, Equatable {
    public let minimum: Double
    public let average: Double
    public let maximum: Double
    /// How many readings the average is over. Without it two aggregates cannot
    /// be merged — the mean of means is the true mean only when both cover the
    /// same count, which neither a re-flush nor a rollup across a gap does.
    public let count: Int

    public init(minimum: Double, average: Double, maximum: Double, count: Int = 1) {
        self.minimum = minimum
        self.average = average
        self.maximum = maximum
        self.count = count
    }

    public init(_ value: Double) {
        self.init(minimum: value, average: value, maximum: value)
    }
}

/// A stored row: one series, one bucket, one aggregate.
public struct HistorySample: Sendable, Codable, Equatable {
    public let series: MetricSeries
    /// Start of the bucket, aligned to the tier's width.
    public let timestamp: Date
    public let aggregate: Aggregate

    /// Public because the preview harness writes a synthetic day into a
    /// throwaway store — the app's own charts are checked against rows that
    /// went through the same reader as the real ones.
    public init(series: MetricSeries, timestamp: Date, aggregate: Aggregate) {
        self.series = series
        self.timestamp = timestamp
        self.aggregate = aggregate
    }
}

/// Several series read over one range, at one tier. A type rather than a bare
/// dictionary because the tier is part of the answer: it says how wide a bucket
/// is, and therefore which row holds a given moment.
public struct HistorySlice: Sendable, Equatable {
    public let tier: HistoryTier
    public let start: Date
    public let end: Date
    private let rows: [MetricSeries: [HistorySample]]

    public init(
        tier: HistoryTier,
        start: Date,
        end: Date,
        rows: [MetricSeries: [HistorySample]]
    ) {
        self.tier = tier
        self.start = start
        self.end = end
        self.rows = rows
    }

    /// Every stored bucket of one series, oldest first. Empty rather than
    /// absent for a series with nothing recorded.
    public subscript(series: MetricSeries) -> [HistorySample] {
        rows[series] ?? []
    }

    /// The same buckets, split into unbroken runs.
    ///
    /// A sleeping Mac writes nothing, so two neighbouring rows can be hours
    /// apart. Handed to a chart as one series that reads as a straight line
    /// across the hole — a ramp nothing ever measured. Split here because this
    /// is the only type holding both the rows and the tier that says how far
    /// apart two consecutive buckets are entitled to be.
    public func runs(_ series: MetricSeries) -> [[HistorySample]] {
        let samples = self[series]
        guard !samples.isEmpty else { return [] }

        // Strictly greater than one bucket: buckets are aligned to the tier's
        // width, so neighbours in an unbroken stretch are exactly one width
        // apart and only a missing bucket can push them further.
        let width = TimeInterval(tier.seconds)
        var runs: [[HistorySample]] = [[samples[0]]]
        for (previous, sample) in zip(samples, samples.dropFirst()) {
            if sample.timestamp.timeIntervalSince(previous.timestamp) > width {
                runs.append([])
            }
            runs[runs.count - 1].append(sample)
        }
        return runs
    }

    public var isEmpty: Bool {
        rows.values.allSatisfy(\.isEmpty)
    }

    /// Where a cursor anywhere in the slice snaps to.
    public func bucket(containing date: Date) -> Date {
        tier.bucketStart(of: date)
    }

    /// The buckets a cursor can sit on: the first that starts inside the slice
    /// through the last that starts before it ends. `nil` when no whole bucket
    /// starts inside it.
    ///
    /// Not `start...end` — those are wall-clock edges. `start` is "now minus the
    /// span" and almost never aligned, so the bucket containing it begins before
    /// the slice, and clamping there puts the cursor outside the range the view
    /// checks it against.
    public var cursorRange: ClosedRange<Date>? {
        let containing = tier.bucketStart(of: start)
        let first =
            containing < start
            ? containing.addingTimeInterval(TimeInterval(tier.seconds)) : containing
        let last = tier.bucketStart(of: end)
        guard first <= last else { return nil }
        return first...last
    }

    /// The newest bucket holding a row, in whichever series has one.
    public var latestRecorded: Date? {
        rows.values.compactMap { $0.last?.timestamp }.max()
    }

    /// The bucket `steps` away, for a cursor moved a key at a time. Clamped at
    /// both ends.
    ///
    /// By the tier's width, so it crosses a gap rather than stepping over it —
    /// skipping to the next bucket that holds a row would redraw a night as
    /// shorter than it was. With no cursor yet the answer is the newest bucket
    /// holding something, not the last of the range: the recorder flushes once
    /// a minute, so the right-hand bucket is usually still filling.
    public func bucket(from moment: Date?, steppedBy steps: Int) -> Date? {
        guard let range = cursorRange else { return nil }
        guard let moment else {
            guard let latest = latestRecorded, range.contains(latest) else {
                return range.upperBound
            }
            return latest
        }

        let stepped = tier.bucketStart(of: moment)
            .addingTimeInterval(TimeInterval(steps * tier.seconds))
        return Swift.min(Swift.max(stepped, range.lowerBound), range.upperBound)
    }

    /// `nil` where nothing was recorded, never interpolated: the chart draws a
    /// gap there, and a readout that filled it would disagree with the picture
    /// it annotates.
    public func sample(_ series: MetricSeries, at bucket: Date) -> HistorySample? {
        // A scrub asks this of every series on every pointer move, and the
        // rows come back ordered.
        let samples = self[series]
        var low = samples.startIndex
        var high = samples.endIndex
        while low < high {
            let middle = low + (high - low) / 2
            if samples[middle].timestamp < bucket {
                low = middle + 1
            } else {
                high = middle
            }
        }
        guard low < samples.endIndex, samples[low].timestamp == bucket else { return nil }
        return samples[low]
    }
}

/// Shared by both tier types: a process bucket and a metric bucket reporting
/// the same start have to *be* the same span.
func bucketStart(of date: Date, width: Int) -> Date {
    let interval = date.timeIntervalSince1970
    return Date(timeIntervalSince1970: (interval / Double(width)).rounded(.down) * Double(width))
}
