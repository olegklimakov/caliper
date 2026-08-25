/// What the surfaces currently on screen are drawing.
///
/// Sampling cost is paid for visibility, and the bill is itemised: a panel is
/// not "expensive" in general, it is expensive in the metrics it shows. The
/// four rungs this replaced said only *how much* was open, so opening the CPU
/// panel — which draws no temperature — pulled the sensor sweep from one read
/// every thirty seconds to one every two, and that sweep is the most expensive
/// read in the app by an order of magnitude.
///
/// The app layer owns this value. It is the only side that knows about
/// occlusion, open popovers and window state, and the only side that knows
/// which metrics a given surface draws.
public struct MetricDemand: Sendable, Equatable {
    /// Whether any of this app is on screen. False means the display is asleep
    /// or the menu bar is covered, and everything drops to its slowest rate.
    public let isVisible: Bool

    /// The metrics a visible surface is drawing right now. Everything else
    /// still samples, at the background rate that keeps the history fed.
    public let metrics: Set<MetricKind>

    public init(isVisible: Bool, metrics: Set<MetricKind>) {
        self.isVisible = isVisible
        self.metrics = metrics
    }

    /// Nothing on screen. The app builds its own value from
    /// `areScreensAwake`, so this is the name the three regimes go by when the
    /// cadence table is being reasoned about or tested.
    public static let hidden = MetricDemand(isVisible: false, metrics: [])

    /// The menu bar strip and nothing else.
    ///
    /// Empty, deliberately. The strip is a *background* consumer: its four live
    /// modules already run at the base rate there, and its temperature badge
    /// reads the slow sweep quite happily — a die climbs about 0.4 °C a second,
    /// so a badge refreshed every thirty seconds is never visibly wrong. Only
    /// something a user has opened raises a metric to full rate.
    public static let menuBar = MetricDemand(isVisible: true, metrics: [])

    /// Every metric at full rate, for a surface that draws the lot — the
    /// preview harness and the self-test, which want every sampler running.
    public static let everything = MetricDemand(
        isVisible: true,
        metrics: Set(MetricKind.allCases)
    )
}
