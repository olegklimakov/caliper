import Darwin
import Foundation

/// What one card is about: an application, not a pid.
///
/// "Google Chrome" is Chrome plus forty helpers, and the helpers carry their
/// *own* bundle identifiers (`com.google.Chrome.helper`), so grouping by the
/// pid's literal bundle id would split the family the card exists to unite.
/// What does unite them is the outermost `.app` in the executable path —
/// helpers live inside `Google Chrome.app/Contents/…` — and that rule is a
/// pure function of the path, testable without a filesystem.
public enum ProcessFamilyKey: Sendable, Hashable {
    case bundle(identifier: String, appURL: URL)
    case executable(String)

    /// The outermost `*.app` component's URL, or nil when the path has none.
    static func appBundleURL(forExecutablePath path: String) -> URL? {
        let components = path.split(separator: "/")
        guard let index = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        let bundlePath = "/" + components[...index].joined(separator: "/")
        return URL(fileURLWithPath: bundlePath, isDirectory: true)
    }

    /// nil when the pid's executable path is unreadable — another user's
    /// process cannot anchor a family.
    public static func resolve(pid: pid_t) -> ProcessFamilyKey? {
        guard let path = ResourceUsage.path(for: pid) else { return nil }
        if let appURL = appBundleURL(forExecutablePath: path),
            let identifier = Bundle(url: appURL)?.bundleIdentifier
        {
            return .bundle(identifier: identifier, appURL: appURL)
        }
        guard let name = path.split(separator: "/").last else { return nil }
        return .executable(String(name))
    }

    public static func resolve(executableName: String) -> ProcessFamilyKey {
        .executable(executableName)
    }

    public var displayName: String {
        switch self {
        case .bundle(_, let appURL):
            let name = appURL.lastPathComponent
            return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
        case .executable(let name):
            return name
        }
    }

    public var bundleIdentifier: String? {
        if case .bundle(let identifier, _) = self { return identifier }
        return nil
    }

    /// Whether an executable at this path belongs to the family.
    func contains(executablePath path: String) -> Bool {
        switch self {
        case .bundle(_, let appURL):
            return Self.appBundleURL(forExecutablePath: path) == appURL
        case .executable(let name):
            return path.split(separator: "/").last.map(String.init) == name
        }
    }
}

/// One second of a family's life, everything the card shows.
public struct ProcessCardReading: Sendable, Equatable {
    public struct Member: Sendable, Equatable {
        public let pid: pid_t
        public let name: String
        /// Identity token for the kill re-check; raw mach absolute units.
        public let startTime: UInt64
        public let cpu: Double
        public let footprint: UInt64
        public let lifetimeMaxFootprint: UInt64
        public let readRate: Double
        public let writeRate: Double
        public let power: Double
        public let wakeupsPerSecond: Double
        public let performanceCycleShare: Double?
        public let qos: QoSBreakdown?
        /// Cumulative seconds; 0 also when the accelerator is unavailable —
        /// check the reading's `gpuIsAvailable` before showing it.
        public let gpuTime: Double
        /// Parent outside the family: the process a Quit signal goes to.
        public let isRoot: Bool
        public let isOwnUser: Bool
        /// Awake seconds, not wall-clock — see `ResourceUsage.elapsedSeconds`.
        public let runningFor: TimeInterval

        public init(
            pid: pid_t,
            name: String,
            startTime: UInt64,
            cpu: Double,
            footprint: UInt64,
            lifetimeMaxFootprint: UInt64,
            readRate: Double,
            writeRate: Double,
            power: Double,
            wakeupsPerSecond: Double,
            performanceCycleShare: Double?,
            qos: QoSBreakdown?,
            gpuTime: Double,
            isRoot: Bool,
            isOwnUser: Bool,
            runningFor: TimeInterval
        ) {
            self.pid = pid
            self.name = name
            self.startTime = startTime
            self.cpu = cpu
            self.footprint = footprint
            self.lifetimeMaxFootprint = lifetimeMaxFootprint
            self.readRate = readRate
            self.writeRate = writeRate
            self.power = power
            self.wakeupsPerSecond = wakeupsPerSecond
            self.performanceCycleShare = performanceCycleShare
            self.qos = qos
            self.gpuTime = gpuTime
            self.isRoot = isRoot
            self.isOwnUser = isOwnUser
            self.runningFor = runningFor
        }
    }

    public let sampledAt: Date
    /// Empty means the family has exited.
    public let members: [Member]
    /// Of the cycles the whole family retired this interval, the fraction on
    /// the performance clusters — summed deltas, not an average of member
    /// shares, because cores retire cycles at different rates.
    public let performanceCycleShare: Double?
    public let gpuIsAvailable: Bool

    public init(
        sampledAt: Date,
        members: [Member],
        performanceCycleShare: Double?,
        gpuIsAvailable: Bool
    ) {
        self.sampledAt = sampledAt
        self.members = members
        self.performanceCycleShare = performanceCycleShare
        self.gpuIsAvailable = gpuIsAvailable
    }

    public var cpu: Double { members.reduce(0) { $0 + $1.cpu } }
    public var footprint: UInt64 { members.reduce(0) { $0 &+ $1.footprint } }
    public var readRate: Double { members.reduce(0) { $0 + $1.readRate } }
    public var writeRate: Double { members.reduce(0) { $0 + $1.writeRate } }
    public var power: Double { members.reduce(0) { $0 + $1.power } }
    public var wakeupsPerSecond: Double { members.reduce(0) { $0 + $1.wakeupsPerSecond } }
    public var gpuTime: Double { members.reduce(0) { $0 + $1.gpuTime } }

    /// Summed member tiers; nil when no member reports QoS accounting.
    public var qos: QoSBreakdown? {
        let reported = members.compactMap(\.qos)
        guard let first = reported.first else { return nil }
        return reported.dropFirst().reduce(first) { sum, next in
            QoSBreakdown(
                userInteractive: sum.userInteractive + next.userInteractive,
                userInitiated: sum.userInitiated + next.userInitiated,
                defaultTier: sum.defaultTier + next.defaultTier,
                legacy: sum.legacy + next.legacy,
                utility: sum.utility + next.utility,
                background: sum.background + next.background,
                maintenance: sum.maintenance + next.maintenance
            )
        }
    }
}

public enum TerminationOutcome: Sendable {
    case signalled
    case alreadyExited
    case refused
}

/// The card's live source: one family, once a second, only while a card is
/// open — which is what bounds its cost, per the Phase 7 rule.
///
/// A struct with its state moved into the one task that drives it; nothing
/// here is shared.
public struct ProcessProbe {
    private let family: ProcessFamilyKey
    private var pids = PIDBuffer()
    /// Classification cache: the path syscall is paid once per pid, not once
    /// per tick. Evicted when the pid leaves the process list, so a reused
    /// pid is reclassified — a pid dying *and* being reused between two ticks
    /// is the one window this cannot see.
    private var membership: [pid_t: Bool] = [:]
    private var names: [pid_t: String] = [:]
    private var previous: [pid_t: ResourceUsage.Counters] = [:]
    private var window = RateWindow()
    private var gpu = GPUProcessSampler()

    public init(family: ProcessFamilyKey) {
        self.family = family
    }

    /// nil while the rate window warms up — the first reading needs two ticks.
    public mutating func sample() -> ProcessCardReading? {
        guard let list = pids.read() else { return nil }

        let present = Set(list)
        membership = membership.filter { present.contains($0.key) }
        names = names.filter { present.contains($0.key) }

        var memberCounters: [(pid: pid_t, counters: ResourceUsage.Counters)] = []
        for pid in list where pid > 0 {
            let isMember: Bool
            if let cached = membership[pid] {
                isMember = cached
            } else {
                let path = ResourceUsage.path(for: pid)
                isMember = path.map(family.contains(executablePath:)) ?? false
                membership[pid] = isMember
                if isMember, let path, let name = path.split(separator: "/").last {
                    names[pid] = String(name)
                }
            }
            guard isMember, let counters = ResourceUsage.counters(for: pid) else { continue }
            memberCounters.append((pid, counters))
        }

        defer {
            previous = Dictionary(
                uniqueKeysWithValues: memberCounters.map { ($0.pid, $0.counters) }
            )
        }
        guard let seconds = window.advance(to: .now) else { return nil }

        let gpuTimes: [pid_t: Double]
        if gpu.isAvailable, let sweep = gpu.sample() {
            gpuTimes = Dictionary(
                uniqueKeysWithValues: sweep.processes.map { ($0.pid, $0.gpuTime) }
            )
        } else {
            gpuTimes = [:]
        }

        let memberPids = Set(memberCounters.map(\.pid))
        let ownUID = getuid()
        var cyclesTotal: UInt64 = 0
        var pCyclesTotal: UInt64 = 0

        let members = memberCounters.map { pid, counters -> ProcessCardReading.Member in
            let usage = ProcessSampler.usage(
                pid: pid,
                counters: counters,
                previous: previous[pid],
                seconds: seconds
            )
            cyclesTotal &+= usage.cyclesDelta
            pCyclesTotal &+= usage.pCyclesDelta
            let info = ResourceUsage.shortInfo(for: pid)
            return ProcessCardReading.Member(
                pid: pid,
                name: names[pid] ?? ResourceUsage.name(for: pid),
                startTime: counters.startTime,
                cpu: usage.cpu,
                footprint: counters.physicalFootprint,
                lifetimeMaxFootprint: counters.lifetimeMaxFootprint,
                readRate: usage.readRate,
                writeRate: usage.writeRate,
                power: usage.power,
                wakeupsPerSecond: usage.wakeupsPerSecond,
                performanceCycleShare: usage.performanceCycleShare,
                qos: usage.qos,
                gpuTime: gpuTimes[pid] ?? 0,
                isRoot: info.map { !memberPids.contains($0.ppid) } ?? true,
                isOwnUser: info.map { $0.uid == ownUID } ?? false,
                runningFor: ResourceUsage.elapsedSeconds(sinceMachAbsolute: counters.startTime)
            )
        }
        .sorted { $0.cpu != $1.cpu ? $0.cpu > $1.cpu : $0.pid < $1.pid }

        return ProcessCardReading(
            sampledAt: Date(),
            members: members,
            performanceCycleShare: cyclesTotal == 0
                ? nil
                : Double(min(pCyclesTotal, cyclesTotal)) / Double(cyclesTotal),
            gpuIsAvailable: gpu.isAvailable
        )
    }

    /// Signals one process — after proving it is still the process the card
    /// shows. The confirmation dialog can sit open for minutes, macOS reuses
    /// pids, and a signal to a stranger is the one mistake this feature must
    /// never make.
    public static func terminate(
        pid: pid_t,
        startedAt startTime: UInt64,
        force: Bool
    ) -> TerminationOutcome {
        guard let counters = ResourceUsage.counters(for: pid) else {
            // Unreadable-but-alive is another user's process; without counters
            // there is no identity to verify either way.
            let alive = kill(pid, 0) == 0 || errno == EPERM
            return alive ? .refused : .alreadyExited
        }
        guard counters.startTime == startTime else { return .alreadyExited }
        guard let info = ResourceUsage.shortInfo(for: pid), info.uid == getuid() else {
            return .refused
        }

        guard kill(pid, force ? SIGKILL : SIGTERM) == 0 else {
            return errno == ESRCH ? .alreadyExited : .refused
        }
        return .signalled
    }
}
