import Foundation

/// The series the history keeps.
///
/// Deliberately a short, fixed list of *aggregate* numbers. Per-core loads and
/// per-process rows are what a live panel shows; recording them for two years
/// would multiply the store by the width of the machine and answer a question
/// nobody asks of history.
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

    /// How long rows of this tier are kept.
    ///
    /// Fine detail is only interesting while it is recent: nobody asks what the
    /// CPU did at ten-second resolution last March, but "the last day, second
    /// by second" is exactly what you want after something went wrong.
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

    /// How wide a bucket of this tier is, as a reader writes it.
    public var label: String {
        switch self {
        case .tenSeconds: "10 s"
        case .minute: "1 min"
        case .tenMinutes: "10 min"
        case .hour: "1 h"
        }
    }

    /// The start of the bucket a moment falls in.
    ///
    /// Aligned to absolute time, not to when the app started, so two runs on the
    /// same machine produce rows that line up — and so a reader can find the row
    /// holding a given moment by arithmetic rather than by searching for the
    /// nearest one.
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

/// One bucket of one series: what the metric did over that span.
///
/// Minimum and maximum alongside the average because an average hides exactly
/// what a monitor is for — a machine that averaged 20 % but hit 100 % for
/// thirty seconds is a different machine from one that sat at 20 %.
public struct Aggregate: Sendable, Codable, Equatable {
    public let minimum: Double
    public let average: Double
    public let maximum: Double
    /// How many readings the average is over.
    ///
    /// Stored because without it two aggregates cannot be merged: the mean of
    /// means is only the true mean when both cover the same number of samples,
    /// and neither a re-flushed bucket nor a rollup across a gap does.
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

/// Several series read over one range, at one tier.
///
/// A type rather than a bare dictionary because the tier is part of the answer:
/// it is what says how wide a bucket is, and therefore which row holds a given
/// moment. A caller holding only the rows would have to guess, and a view whose
/// whole purpose is "all of these at the same instant" cannot afford to.
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

    /// Every stored bucket of one series, oldest first.
    ///
    /// Empty rather than absent for a series with nothing recorded: a machine
    /// whose sensors this build cannot read has no temperature history, and
    /// that is a fact about the machine, not a failure to report.
    public subscript(series: MetricSeries) -> [HistorySample] {
        rows[series] ?? []
    }

    /// The same buckets, split into unbroken runs.
    ///
    /// A stored row exists only for a bucket that was actually recorded, so two
    /// neighbouring elements of the array can be hours apart — a sleeping Mac
    /// writes nothing. Handed to a chart as one series, that reads as a
    /// straight line across the hole, and the min/max band fills the space
    /// under it: a smooth sixteen-hour ramp that nothing ever measured. On a
    /// monitor whose whole claim is a real record of what the machine did,
    /// inventing the quiet hours is the worst thing the picture can do.
    ///
    /// The split lives here because this is the only type holding both halves
    /// of the rule — the rows, and the tier that says how far apart two
    /// consecutive buckets are entitled to be.
    public func runs(_ series: MetricSeries) -> [[HistorySample]] {
        let samples = self[series]
        guard !samples.isEmpty else { return [] }

        // Strictly greater than one bucket: buckets are aligned to the tier's
        // width, so neighbours in an unbroken stretch are exactly one width
        // apart and only a missing bucket can push them further.
        let width = TimeInterval(tier.seconds)
        var runs: [[HistorySample]] = []
        var current: [HistorySample] = [samples[0]]
        for sample in samples.dropFirst() {
            if let previous = current.last,
                sample.timestamp.timeIntervalSince(previous.timestamp) > width
            {
                runs.append(current)
                current = []
            }
            current.append(sample)
        }
        runs.append(current)
        return runs
    }

    public var isEmpty: Bool {
        rows.values.allSatisfy(\.isEmpty)
    }

    /// The bucket a moment belongs to — where a cursor anywhere in the slice
    /// snaps to.
    public func bucket(containing date: Date) -> Date {
        tier.bucketStart(of: date)
    }

    /// The buckets a cursor can sit on: the first one that starts inside the
    /// slice, through the last one that starts before it ends.
    ///
    /// Not `start...end`. Those are wall-clock edges, and only a *bucket's*
    /// start is somewhere a cursor means anything. `start` is "now minus the
    /// span" and is therefore almost never aligned, so the bucket containing it
    /// begins before the slice does — clamping there would put the cursor
    /// outside the range the view then checks it against, and the rule would
    /// simply vanish.
    ///
    /// `nil` when no whole bucket starts inside the slice at all, which a span
    /// narrower than one bucket can produce.
    public var cursorRange: ClosedRange<Date>? {
        let containing = tier.bucketStart(of: start)
        let first =
            containing < start
            ? containing.addingTimeInterval(TimeInterval(tier.seconds)) : containing
        let last = tier.bucketStart(of: end)
        guard first <= last else { return nil }
        return first...last
    }

    /// The newest bucket that actually holds a row, in whichever series has one.
    public var latestRecorded: Date? {
        rows.values.compactMap { $0.last?.timestamp }.max()
    }

    /// The bucket `steps` away from a moment, for a cursor being moved a key
    /// at a time.
    ///
    /// By the tier's width, so it crosses a gap rather than stepping over it: a
    /// stretch the Mac slept through is still made of buckets, and landing on
    /// one and reading "—" is the truth about that moment. Skipping to the next
    /// bucket that happens to hold a row would quietly redraw the night as
    /// shorter than it was.
    ///
    /// With no cursor yet, the answer is the newest bucket that has something
    /// in it, whichever way the first key went. Not simply the last bucket of
    /// the range: the recorder flushes once a minute and the rollup runs every
    /// ten, so the bucket at the right-hand edge is usually still filling, and a
    /// first keypress landing there would answer "—" and look broken.
    ///
    /// Clamped at both ends, so holding an arrow down parks the cursor on the
    /// edge instead of walking it off the axis.
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

    /// What one series did over one bucket, or `nil` where nothing was
    /// recorded: the Mac asleep, or a sampler that had not answered yet.
    ///
    /// Never interpolated across. The chart draws a gap there, and a readout
    /// that quietly filled it with the neighbouring value would disagree with
    /// the picture it is annotating.
    public func sample(_ series: MetricSeries, at bucket: Date) -> HistorySample? {
        // A search rather than a scan: the rows come back ordered by timestamp,
        // and a scrub asks this of every series on every pointer move.
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

/// Where a bucket of a given width starts, aligned to absolute time.
///
/// Shared by both tier types rather than written out twice: a process bucket and
/// a metric bucket that report the same start have to *be* the same span, and
/// two copies of this arithmetic could drift apart.
func bucketStart(of date: Date, width: Int) -> Date {
    let interval = date.timeIntervalSince1970
    return Date(timeIntervalSince1970: (interval / Double(width)).rounded(.down) * Double(width))
}
