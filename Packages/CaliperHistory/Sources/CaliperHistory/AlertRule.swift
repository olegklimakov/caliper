import Foundation

/// A standing question about the record: has this series been over — or under —
/// a threshold for a stretch of time.
///
/// Asked of the *store*, never of the live tick, and that is the whole point:
/// "over 80 %" is a spike anyone can see, "over 80 % for five minutes" is a
/// fact about buckets. It is also the shape of request that has sat open on
/// other monitors' trackers for years, because without a history there is
/// nothing to ask it of.
public struct AlertRule: Sendable, Equatable, Codable, Identifiable {
    public let id: UUID
    public var series: MetricSeries
    public var comparison: AlertComparison
    /// In the series' own unit, unscaled — a fraction for the fractions, watts
    /// for watts, degrees for temperature. The readout formats; the rule does
    /// not carry a presentation.
    public var threshold: Double
    public var duration: TimeInterval
    public var isEnabled: Bool

    public init(
        id: UUID = UUID(),
        series: MetricSeries,
        comparison: AlertComparison,
        threshold: Double,
        duration: TimeInterval,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.series = series
        self.comparison = comparison
        self.threshold = threshold
        self.duration = duration
        self.isEnabled = isEnabled
    }

    /// The windows offered, and why they stop where they do: the finest tier
    /// keeps a day, and a rule whose window outlives the rows it reads would
    /// go quiet without ever saying so.
    public static let durations: [TimeInterval] = [300, 900, 3600, 6 * 3600]
}

public enum AlertComparison: String, Sendable, Equatable, Codable, CaseIterable {
    case above
    case below
}

/// Whether a rule's condition holds over the record, and nothing else — no
/// state, no delivery, no memory of having fired. Those belong to whoever owns
/// the notifications; this is the part that can be tested without a machine.
public enum AlertEvaluator {
    /// The window a rule is asked about: the writer batches a minute at a time,
    /// so the newest minute of buckets is missing by construction. A rule
    /// evaluated up to `now` would see that hole and conclude the condition
    /// lapsed, every single pass.
    ///
    /// The cost is that an alert arrives up to a minute after the condition has
    /// held for its full duration. That is a real delay and the readout says so
    /// rather than pretending to be live.
    public static func window(for rule: AlertRule, now: Date) -> (start: Date, end: Date) {
        let end = now.addingTimeInterval(-HistoryRecorder.flushInterval)
        return (end.addingTimeInterval(-rule.duration), end)
    }

    /// True when every bucket in the window is there *and* satisfies the rule.
    ///
    /// A gap is not a satisfied condition. A sleeping Mac records nothing, and
    /// "nothing recorded" is not "over eighty per cent" — firing on a hole
    /// would make every overnight the loudest night of the week.
    ///
    /// Compared against the bucket's own extreme rather than its average: a
    /// rule about being over a threshold is not satisfied by a bucket that
    /// averaged over it while dipping under, and the stored min/max is exactly
    /// what makes that answerable.
    public static func isFiring(_ rule: AlertRule, over samples: [HistorySample], now: Date) -> Bool {
        guard rule.isEnabled else { return false }
        let expected = Int((rule.duration / Double(HistoryTier.tenSeconds.seconds)).rounded())
        guard expected > 0, samples.count >= expected else { return false }

        return samples.allSatisfy { sample in
            switch rule.comparison {
            case .above: sample.aggregate.minimum > rule.threshold
            case .below: sample.aggregate.maximum < rule.threshold
            }
        }
    }
}

/// What a rule has been doing, kept by whoever evaluates on a timer.
///
/// The reason this exists rather than a bare boolean: a rule that holds for an
/// hour is one notification, not one every pass. It fires on the edge into
/// firing and arms again only once the condition stops holding.
public struct AlertState: Sendable, Equatable {
    private var firing: Set<UUID> = []

    public init() {}

    /// Records what the evaluator found and answers whether this is the moment
    /// to tell someone.
    public mutating func shouldAnnounce(_ rule: AlertRule, isFiring: Bool) -> Bool {
        let wasFiring = firing.contains(rule.id)
        if isFiring {
            firing.insert(rule.id)
        } else {
            firing.remove(rule.id)
        }
        return isFiring && !wasFiring
    }

    /// A rule that has been edited or switched off starts again from armed —
    /// otherwise raising a threshold past a firing condition leaves it silent
    /// until it clears at the *old* one.
    public mutating func forget(_ id: UUID) {
        firing.remove(id)
    }

    public func isFiring(_ id: UUID) -> Bool { firing.contains(id) }
}
