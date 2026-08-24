import Foundation
import IOKit

/// Works out which logical cores belong to which performance cluster.
///
/// This cannot be guessed from `hw.perflevel*` alone. On an M5 Pro the fastest
/// level (`perflevel0`, "Super", 5 cores) occupies logical CPUs 10–14 while the
/// slower level sits at 0–9 — the reverse of the usual assumption — and the
/// IORegistry labels those clusters `P` and `M` rather than the familiar
/// `P`/`E`. So the layout is read from the IORegistry and matched against the
/// sysctl performance levels, and only when the match is unambiguous. Anything
/// unexpected yields no clusters at all and the UI falls back to unlabeled
/// per-core readings.
enum CPUTopology {
    struct ClusterRun: Equatable {
        let type: String
        let coreIndices: [Int]
    }

    struct PerformanceLevel: Equatable {
        let name: String
        let logicalCores: Int
    }

    /// Clusters ordered fastest first, parallel to `hw.perflevel*`. Empty when
    /// the layout could not be established.
    static func clusters(logicalCores: Int) -> [HostInfo.CoreCluster] {
        guard let cores = registryCores(), cores.count == logicalCores else { return [] }
        return matched(runs: contiguousRuns(of: cores), levels: performanceLevels()) ?? []
    }

    /// Pairs IORegistry cluster runs with sysctl performance levels.
    ///
    /// Split out from the hardware reads so the matching rules can be tested
    /// against the layouts of machines this one is not.
    static func matched(runs: [ClusterRun], levels: [PerformanceLevel]) -> [HostInfo.CoreCluster]? {
        guard !levels.isEmpty, runs.count == levels.count else { return nil }
        return matchBySize(runs, levels) ?? matchBySpeedRank(runs, levels)
    }

    /// Preferred: the levels have different core counts, so sizes identify them.
    private static func matchBySize(
        _ runs: [ClusterRun],
        _ levels: [PerformanceLevel]
    ) -> [HostInfo.CoreCluster]? {
        let sizes = levels.map(\.logicalCores)
        guard Set(sizes).count == sizes.count else { return nil }

        var remaining = runs
        var clusters: [HostInfo.CoreCluster] = []
        for level in levels {
            guard
                let match = remaining.firstIndex(where: { $0.coreIndices.count == level.logicalCores })
            else { return nil }
            clusters.append(
                HostInfo.CoreCluster(
                    name: level.name,
                    coreIndices: remaining.remove(at: match).coreIndices
                )
            )
        }
        return clusters
    }

    /// Fallback for equal-sized levels (M1 and M2 are 4+4): rank the runs by how
    /// fast their cluster type is and pair them with the levels, which sysctl
    /// already reports fastest first.
    private static func matchBySpeedRank(
        _ runs: [ClusterRun],
        _ levels: [PerformanceLevel]
    ) -> [HostInfo.CoreCluster]? {
        let ranked = runs.compactMap { run in speedRank(of: run.type).map { (run: run, rank: $0) } }
        guard ranked.count == runs.count else { return nil }

        let fastestFirst = ranked.sorted { $0.rank > $1.rank }
        guard Set(fastestFirst.map(\.rank)).count == fastestFirst.count else { return nil }

        var clusters: [HostInfo.CoreCluster] = []
        for (candidate, level) in zip(fastestFirst, levels) {
            guard candidate.run.coreIndices.count == level.logicalCores else { return nil }
            clusters.append(
                HostInfo.CoreCluster(name: level.name, coreIndices: candidate.run.coreIndices)
            )
        }
        return clusters
    }

    /// Higher is faster. An unknown letter means the machine is newer than this
    /// table, which is a reason to degrade rather than to guess.
    private static func speedRank(of clusterType: String) -> Int? {
        switch clusterType {
        case "E": 0
        case "M": 1
        case "P": 2
        default: nil
        }
    }

    /// Groups neighbouring cores of the same type. Two physical clusters of the
    /// same type (this machine has two `M` clusters) form a single run, which is
    /// what one performance level describes.
    static func contiguousRuns(of cores: [(index: Int, type: String)]) -> [ClusterRun] {
        var runs: [ClusterRun] = []
        for core in cores {
            if let last = runs.last, last.type == core.type {
                runs[runs.count - 1] = ClusterRun(
                    type: last.type,
                    coreIndices: last.coreIndices + [core.index]
                )
            } else {
                runs.append(ClusterRun(type: core.type, coreIndices: [core.index]))
            }
        }
        return runs
    }

    // MARK: - Hardware reads

    private static func performanceLevels() -> [PerformanceLevel] {
        let count = Sysctl.value("hw.nperflevels", as: Int32.self).map(Int.init) ?? 0
        return (0..<count).compactMap { level in
            guard let cores = Sysctl.value("hw.perflevel\(level).logicalcpu", as: Int32.self) else {
                return nil
            }
            let name = Sysctl.string("hw.perflevel\(level).name") ?? "Level \(level)"
            return PerformanceLevel(name: name, logicalCores: Int(cores))
        }
    }

    /// Every `cpu` device in the IORegistry, sorted by logical CPU index — the
    /// same order `host_processor_info` reports load in.
    private static func registryCores() -> [(index: Int, type: String)]? {
        var cores: [(index: Int, type: String)] = []
        IORegistry.forEachService(matching: "IOPlatformDevice") { service in
            guard IORegistry.string(service, "device_type") == "cpu",
                let index = IORegistry.integer(service, "logical-cpu-id"),
                let type = IORegistry.string(service, "cluster-type")
            else { return }
            cores.append((index, type))
        }

        guard !cores.isEmpty else { return nil }
        return cores.sorted { $0.index < $1.index }
    }
}
