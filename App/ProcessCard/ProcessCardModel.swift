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
    private(set) var icon: NSImage?
    var span: TimeInterval = 24 * 3600 {
        didSet { loadHistory() }
    }

    private let reader: HistoryReader?
    private var probeTask: Task<Void, Never>?
    private var historyTask: Task<Void, Never>?

    init(target: ProcessCardTarget, reader: HistoryReader?) {
        self.target = target
        self.reader = reader
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
        history: ProcessNameHistory?
    ) {
        self.target = target
        self.family = family
        self.reading = reading
        self.presence = presence
        self.history = history
        reader = nil
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
        let family = family
        probeTask = Task.detached(priority: .userInitiated) { [weak self] in
            var probe = ProcessProbe(family: family)
            while !Task.isCancelled {
                let reading = probe.sample()
                await MainActor.run { self?.apply(reading) }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        loadHistory()
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
        }
    }

    private func loadHistory() {
        guard let reader else { return }
        historyTask?.cancel()
        let name = target.name
        let span = span
        historyTask = Task { [weak self] in
            let history = try? await reader.processHistory(name: name, span: span)
            guard !Task.isCancelled else { return }
            self?.history = history
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
