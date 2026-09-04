import AppKit
import CaliperCore
import CaliperHistory
import Observation

/// What a card is opened on: a live pid from a panel row, or a bare name from
/// the overview's consumers — which may belong to a process that no longer
/// exists, and that is a valid card.
enum ProcessCardTarget: Hashable {
    case pid(pid_t, name: String)
    case name(String)

    var name: String {
        switch self {
        case .pid(_, let name): name
        case .name(let name): name
        }
    }
}

/// The card's state: identity, one reading a second, and the history strip.
///
/// The probe runs only while the card is on screen — `start()` on appear,
/// `stop()` on disappear — which is what bounds its cost per the Phase 7
/// rule. ⌘H keeps the window and therefore the probe: occlusion is not
/// close, and one rusage-plus-GPU pass a second is the accepted price.
@MainActor
@Observable
final class ProcessCardModel {
    enum Presence: Equatable {
        case warming
        case live
        case exited(lastSeen: Date)
    }

    let target: ProcessCardTarget
    private(set) var family: ProcessFamilyKey
    private(set) var reading: ProcessCardReading?
    private(set) var presence: Presence = .warming
    private(set) var history: ProcessNameHistory?
    /// What the process drew over the span on screen. A floor while it is
    /// unpinned — see `ProcessEnergy`.
    private(set) var energy: ProcessEnergy?
    /// How many times this name's processes have been born since local
    /// midnight. Its own span rather than the strip's: "restarted 14 times"
    /// is asked about a day, and the answer would change meaning if it
    /// followed the 1 H button.
    private(set) var starts: ProcessStarts?
    /// The machine's own stored series over the span on screen — what the
    /// card's GPU and power tiles draw behind their live readings. Read with
    /// the process's history and over the same span, so one span button
    /// governs everything on the card.
    ///
    /// Split into runs here rather than in the view: the probe replaces
    /// `reading` once a second, and `HistorySlice.runs(_:)` walking a day of
    /// buckets on every one of those is work for an answer that changes when
    /// the span button does.
    private(set) var gpuRuns: [[HistorySample]] = []
    private(set) var batteryRuns: [[HistorySample]] = []

    /// The strip's right edge: bars are placed against the moment the history
    /// was asked, so buckets missing at the leading edge read as the gaps
    /// they are.
    private(set) var historyEnd = Date()
    private(set) var icon: NSImage?
    var span: TimeInterval = 24 * 3600 {
        didSet { loadHistory() }
    }

    private let reader: HistoryReader?
    private let preferences: Preferences?
    private var probeTask: Task<Void, Never>?
    private var historyTask: Task<Void, Never>?

    init(target: ProcessCardTarget, reader: HistoryReader?, preferences: Preferences?) {
        self.target = target
        self.reader = reader
        self.preferences = preferences
        switch target {
        case .pid(let pid, let name):
            family = ProcessFamilyKey.resolve(pid: pid) ?? .resolve(executableName: name)
        case .name(let name):
            family = .resolve(executableName: name)
        }
        resolveIcon()
    }

    /// For the preview harness: `ImageRenderer` draws once and runs no tasks.
    init(
        preloaded target: ProcessCardTarget,
        family: ProcessFamilyKey,
        reading: ProcessCardReading?,
        presence: Presence,
        history: ProcessNameHistory?,
        energy: ProcessEnergy? = nil,
        starts: ProcessStarts? = nil,
        machine: HistorySlice? = nil,
        historyEnd: Date = Date(),
        preferences: Preferences? = nil
    ) {
        self.target = target
        self.family = family
        self.reading = reading
        self.presence = presence
        self.history = history
        self.energy = energy
        self.starts = starts
        gpuRuns = machine?.runs(.gpuUtilisation) ?? []
        batteryRuns = machine?.runs(.batteryCharge) ?? []
        self.historyEnd = historyEnd
        self.preferences = preferences
        reader = nil
    }

    /// Whether every bucket of this name is recorded from here on, rather than
    /// only the ones it ranks in.
    var isPinned: Bool {
        preferences?.pinnedProcesses.contains(target.name) ?? false
    }

    var canPin: Bool {
        guard let preferences else { return false }
        return isPinned || preferences.hasRoomForAPin
    }

    func togglePin() {
        preferences?.setPinned(!isPinned, for: target.name)
    }

    var displayName: String { family.displayName }

    /// The processes a Quit signal goes to: family roots, own user, and only
    /// while the whole family is signallable — a mixed family offers no
    /// button rather than a partial one.
    var quitTargets: [ProcessCardReading.Member] {
        guard case .live = presence, let reading else { return [] }
        let roots = reading.members.filter(\.isRoot)
        guard !roots.isEmpty, roots.allSatisfy(\.isOwnUser) else { return [] }
        return roots
    }

    func start() {
        guard probeTask == nil else { return }
        startProbe()
        loadHistory()
    }

    private func startProbe() {
        let family = family
        probeTask = Task.detached(priority: .userInitiated) { [weak self] in
            var probe = ProcessProbe(family: family)
            while !Task.isCancelled {
                let reading = probe.sample()
                await MainActor.run { self?.apply(reading) }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        probeTask?.cancel()
        probeTask = nil
        historyTask?.cancel()
        historyTask = nil
    }

    func terminate(force: Bool) {
        for member in quitTargets {
            _ = ProcessProbe.terminate(
                pid: member.pid,
                startedAt: member.startTime,
                force: force
            )
        }
    }

    private func apply(_ new: ProcessCardReading?) {
        guard let new else { return }
        // The last live moment, not "now": the probe noticing is not the
        // process ending.
        let lastLive = reading?.sampledAt
        reading = new
        if new.members.isEmpty {
            if case .exited = presence {} else {
                presence = .exited(lastSeen: lastLive ?? new.sampledAt)
            }
        } else {
            presence = .live
            upgradeFamilyIfNeeded(from: new)
        }
    }

    /// A card opened on a bare name starts as an executable family — the
    /// overview's consumer rows carry names only. The first live member says
    /// which app that name belongs to, and the bundle family is the better
    /// card: the icon, the identifier, and the helpers the name alone cannot
    /// see. The probe restarts because it classifies against the family it
    /// was born with.
    private func upgradeFamilyIfNeeded(from new: ProcessCardReading) {
        guard case .executable = family,
            let pid = new.members.first?.pid,
            let resolved = ProcessFamilyKey.resolve(pid: pid),
            case .bundle = resolved
        else { return }
        family = resolved
        resolveIcon()
        probeTask?.cancel()
        startProbe()
    }

    /// By name, where the live half of the card is by family — deliberately.
    ///
    /// The store keys on the executable name, and the registry's paths could
    /// resolve a bundle to its helpers' names at read time. Two things say no.
    /// Summing them makes every *bar* a floor rather than only the gaps — a
    /// helper that did not rank is missing from its bucket — which is the one
    /// property the strip exists to have. And a pin is per name: promising
    /// "every bucket" for a family would pin forty of Chrome's helpers against
    /// a cap of ten, at forty times the 0.7 MB a fortnight settings quotes.
    ///
    /// So the strip says which name it is drawn for, in its heading and in both
    /// its captions, rather than claiming the app's total.
    private func loadHistory() {
        guard let reader else { return }
        historyTask?.cancel()
        let name = target.name
        let span = span
        let asked = Date()
        let midnight = Calendar.current.startOfDay(for: asked)
        historyTask = Task { [weak self] in
            let history = try? await reader.processHistory(name: name, span: span, now: asked)
            let energy = try? await reader.processEnergy(name: name, span: span, now: asked)
            let starts = try? await reader.processStarts(name: name, from: midnight, to: asked)
            // One read for both, so the two tiles cannot end up drawing
            // different spans of the same moment.
            let machine = try? await reader.slice(
                [.gpuUtilisation, .batteryCharge],
                span: span,
                now: asked
            )
            guard !Task.isCancelled else { return }
            self?.history = history
            self?.energy = energy
            self?.starts = starts
            self?.gpuRuns = machine?.runs(.gpuUtilisation) ?? []
            self?.batteryRuns = machine?.runs(.batteryCharge) ?? []
            self?.historyEnd = asked
        }
    }

    private func resolveIcon() {
        switch target {
        case .pid(let pid, _):
            if let application = NSRunningApplication(processIdentifier: pid),
                let icon = application.icon
            {
                self.icon = icon
                return
            }
        case .name:
            break
        }
        if case .bundle(_, let appURL) = family {
            icon = NSWorkspace.shared.icon(forFile: appURL.path)
        }
    }
}
