/// What the surfaces currently on screen are drawing.
///
/// Per metric, not per surface: a panel is not "expensive" in general, it is
/// expensive in the metrics it shows. A bare "how much is open" would pull the
/// sensor sweep from one read every thirty seconds to one every two whenever the
/// CPU panel opened, and that sweep is the most expensive read in the app by an
/// order of magnitude.
///
/// The app layer owns this value: it is the only side that knows about
/// occlusion, open popovers and window state, and which metrics a surface
/// draws.
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

    /// Nothing on screen. The app builds its own value from `areScreensAwake`;
    /// this is the name the regime goes by when the cadence table is being
    /// reasoned about or tested.
    public static let hidden = MetricDemand(isVisible: false, metrics: [])

    /// The menu bar strip, and empty deliberately: the strip is a *background*
    /// consumer. Its four live modules already run at the base rate, and a die
    /// climbs about 0.4 °C a second, so a badge refreshed every thirty seconds
    /// is never visibly wrong. Only something a user opened raises a metric.
    public static let menuBar = MetricDemand(isVisible: true, metrics: [])

    /// Every metric at full rate, for a surface that draws the lot — the
    /// preview harness and the self-test, which want every sampler running.
    public static let everything = MetricDemand(
        isVisible: true,
        metrics: Set(MetricKind.allCases)
    )
}
