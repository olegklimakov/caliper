import Foundation

/// Drives every sampler from a single timer and publishes composed snapshots.
///
/// One timer for the whole app is the central footprint decision: each
/// additional repeating timer is another periodic wakeup, and wakeups — not
/// arithmetic — are what a monitor costs the machine. Slower metrics are
/// divisors of the base tick (see `CadenceTable`), and the timer is scheduled
/// with leeway so the kernel can coalesce our wakeup with others.
///
/// Samplers are stored here as plain values, so their delta state is isolated
/// by the actor rather than by a lock.
public actor SamplingCoordinator {
    private let host: HostInfo
    private let queue = DispatchQueue(label: "com.olegklimakov.caliper.sampling", qos: .utility)

    private var activityLevel: ActivityLevel
    private var tickCount: UInt64 = 0
    private var lastTick: ContinuousClock.Instant?
    private var timer: DispatchSourceTimer?
    private var subscribers: [UUID: AsyncStream<SystemSnapshot>.Continuation] = [:]

    private var cpuSampler = CPUSampler()
    private let memorySampler = MemorySampler()
    private var networkSampler = NetworkSampler()
    private var diskSampler = DiskActivitySampler()
    private let volumeSampler = VolumeSampler()
    private let connectionSampler = ConnectionSampler()
    private let temperatureSampler = TemperatureSampler()
    private let fanSampler = FanSampler()
    private let driveHealthSampler = DriveHealthSampler()
    private var processSampler = ProcessSampler()
    private var selfSampler = SelfMetricsSampler()

    private var latestCPU: CPUSample?
    private var latestMemory: MemorySample?
    private var latestNetwork: NetworkSample?
    private var latestDiskActivity: DiskActivitySample?
    private var latestVolumes: [VolumeSample]?
    private var latestConnection: ConnectionSample?
    /// Holds whatever the last probe found, empty arrays included, so that a
    /// machine reporting nothing is not mistaken for one that has not been
    /// sampled yet — which would re-probe on every single tick.
    private var latestSensors: SensorsSample?
    private var latestDriveHealth: DriveHealth?
    private var latestProcesses: ProcessesSample?
    private var latestSelfMetrics: SelfMetrics?

    /// Base tick of the whole app. Everything slower is a multiple of this.
    public static let baseInterval: Duration = .seconds(1)

    public init(host: HostInfo = .current(), activityLevel: ActivityLevel = .menuBarOnly) {
        self.host = host
        self.activityLevel = activityLevel
    }

    // MARK: - Lifecycle

    public func start() {
        guard timer == nil else { return }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(
            deadline: .now() + .seconds(1),
            repeating: .seconds(1),
            leeway: .milliseconds(200)
        )
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            Task { await self.timerFired() }
        }
        timer.resume()
        self.timer = timer
    }

    public func stop() {
        timer?.cancel()
        timer = nil
        for continuation in subscribers.values {
            continuation.finish()
        }
        subscribers.removeAll()
    }

    public func setActivityLevel(_ level: ActivityLevel) {
        activityLevel = level
    }

    // MARK: - Output

    /// A stream of composed snapshots, one per tick.
    ///
    /// Several consumers subscribe at once — menu bar renderers, an open panel
    /// and the history recorder all watch the same ticks — so each caller gets
    /// its own stream. Only the newest snapshot is buffered: a consumer that
    /// falls behind wants current values, not a backlog of stale ones.
    public func snapshots() -> AsyncStream<SystemSnapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<SystemSnapshot>.makeStream(
            bufferingPolicy: .bufferingNewest(1)
        )
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeSubscriber(id) }
        }
        subscribers[id] = continuation
        return stream
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers.removeValue(forKey: id)
    }

    // MARK: - Sampling

    /// Runs a tick from the timer, dropping the ones that bunch up.
    ///
    /// Each timer event hops onto the actor as its own task, so a tick that
    /// overruns its interval — a pid sweep on a loaded machine — leaves the
    /// next ones queued behind it. Running them back to back would report
    /// several "seconds" of load inside a few milliseconds.
    private func timerFired() {
        let now = ContinuousClock.now
        if let lastTick, now - lastTick < Self.baseInterval / 2 { return }
        lastTick = now
        tick(at: now)
    }

    /// Samples every metric due on this tick and publishes the result.
    ///
    /// Internal rather than private so tests can drive ticks directly instead of
    /// waiting on wall-clock time.
    func tick(at instant: ContinuousClock.Instant = .now) {
        tickCount += 1

        if shouldSample(.cpu, hasValue: latestCPU != nil),
            let cpu = cpuSampler.sample(clusters: host.coreClusters)
        {
            latestCPU = cpu
        }
        if shouldSample(.memory, hasValue: latestMemory != nil),
            let memory = memorySampler.sample(totalMemory: host.physicalMemory)
        {
            latestMemory = memory
        }
        if shouldSample(.network, hasValue: latestNetwork != nil),
            let network = networkSampler.sample(at: instant)
        {
            latestNetwork = network
        }
        if shouldSample(.diskActivity, hasValue: latestDiskActivity != nil),
            let disk = diskSampler.sample(at: instant)
        {
            latestDiskActivity = disk
        }
        if shouldSample(.volumes, hasValue: latestVolumes != nil) {
            latestVolumes = volumeSampler.sample()
        }
        if shouldSample(.connection, hasValue: latestConnection != nil) {
            latestConnection = connectionSampler.sample()
        }
        if temperatureSampler.isAvailable || fanSampler.isAvailable,
            shouldSample(.sensors, hasValue: latestSensors != nil)
        {
            latestSensors = SensorsSample(
                temperatures: temperatureSampler.sample(),
                fans: fanSampler.sample()
            )
        }
        if driveHealthSampler.isAvailable,
            shouldSample(.driveHealth, hasValue: latestDriveHealth != nil)
        {
            latestDriveHealth = driveHealthSampler.sample()
        }
        if shouldSample(.processes, hasValue: latestProcesses != nil),
            let processes = processSampler.sample(at: instant)
        {
            latestProcesses = processes
        }
        if shouldSample(.selfMetrics, hasValue: latestSelfMetrics != nil),
            let metrics = selfSampler.sample(at: instant)
        {
            latestSelfMetrics = metrics
        }

        let snapshot = latestSnapshot()
        for continuation in subscribers.values {
            continuation.yield(snapshot)
        }
    }

    /// The most recent value of every metric, without waiting for the next tick.
    public func latestSnapshot() -> SystemSnapshot {
        SystemSnapshot(
            timestamp: Date(),
            host: host,
            cpu: latestCPU,
            memory: latestMemory,
            network: latestNetwork,
            diskActivity: latestDiskActivity,
            volumes: latestVolumes,
            connection: latestConnection,
            sensors: sensors(),
            driveHealth: latestDriveHealth,
            processes: latestProcesses,
            selfMetrics: latestSelfMetrics
        )
    }

    /// A machine that reports neither temperatures nor fans gets `nil`, and the
    /// Sensors feature disappears rather than showing an empty shell. Reporting
    /// only one of the two is a real state — a fanless Mac has temperatures —
    /// and is passed through as it is.
    private func sensors() -> SensorsSample? {
        guard let latestSensors,
            !latestSensors.temperatures.isEmpty || !latestSensors.fans.isEmpty
        else { return nil }
        return latestSensors
    }

    /// Discards every delta baseline. Counters sampled across a sleep describe
    /// hours of suspended time, so the first interval after waking is thrown
    /// away rather than charted as a spike.
    public func resetBaselines() {
        cpuSampler.resetBaseline()
        networkSampler.resetBaseline()
        diskSampler.resetBaseline()
        processSampler.resetBaseline()
        selfSampler.resetBaseline()
        lastTick = nil
    }

    func isDue(_ kind: MetricKind) -> Bool {
        CadenceTable.isDue(kind, tick: tickCount, at: activityLevel)
    }

    /// A metric that has never produced a value is sampled at the first
    /// opportunity: waiting a full slow-cadence interval would leave a panel
    /// blank for up to a minute after launch.
    private func shouldSample(_ kind: MetricKind, hasValue: Bool) -> Bool {
        !hasValue || isDue(kind)
    }
}
