import Testing

@testable import CaliperCore

private func runs(_ pairs: (String, Range<Int>)...) -> [CPUTopology.ClusterRun] {
    pairs.map { CPUTopology.ClusterRun(type: $0.0, coreIndices: Array($0.1)) }
}

private func levels(_ pairs: (String, Int)...) -> [CPUTopology.PerformanceLevel] {
    pairs.map { CPUTopology.PerformanceLevel(name: $0.0, logicalCores: $0.1) }
}

@Test func matchesTheFastClusterEvenWhenItComesLast() {
    // M5 Pro: the "Super" level owns the *last* five logical cores.
    let clusters = CPUTopology.matched(
        runs: runs(("M", 0..<10), ("P", 10..<15)),
        levels: levels(("Super", 5), ("Performance", 10))
    )

    #expect(clusters?.count == 2)
    #expect(clusters?[0].name == "Super")
    #expect(clusters?[0].coreIndices == Array(10..<15))
    #expect(clusters?[1].name == "Performance")
    #expect(clusters?[1].coreIndices == Array(0..<10))
}

@Test func matchesEfficiencyFirstLayouts() {
    // M1 Pro: two efficiency cores at 0–1, eight performance cores after them.
    let clusters = CPUTopology.matched(
        runs: runs(("E", 0..<2), ("P", 2..<10)),
        levels: levels(("Performance", 8), ("Efficiency", 2))
    )

    #expect(clusters?[0].name == "Performance")
    #expect(clusters?[0].coreIndices == Array(2..<10))
    #expect(clusters?[1].coreIndices == Array(0..<2))
}

@Test func breaksSizeTiesByClusterSpeed() {
    // M1: four and four, so only the cluster type says which is which.
    let clusters = CPUTopology.matched(
        runs: runs(("E", 0..<4), ("P", 4..<8)),
        levels: levels(("Performance", 4), ("Efficiency", 4))
    )

    #expect(clusters?[0].name == "Performance")
    #expect(clusters?[0].coreIndices == Array(4..<8))
    #expect(clusters?[1].name == "Efficiency")
    #expect(clusters?[1].coreIndices == Array(0..<4))
}

@Test func degradesRatherThanGuessingOnUnknownHardware() {
    // Equal sizes and a cluster letter this build has never seen.
    #expect(
        CPUTopology.matched(
            runs: runs(("E", 0..<4), ("X", 4..<8)),
            levels: levels(("Performance", 4), ("Efficiency", 4))
        ) == nil
    )

    // More clusters than the machine reports performance levels for.
    #expect(
        CPUTopology.matched(
            runs: runs(("E", 0..<2), ("M", 2..<6), ("P", 6..<10)),
            levels: levels(("Performance", 8), ("Efficiency", 2))
        ) == nil
    )

    #expect(CPUTopology.matched(runs: [], levels: []) == nil)
}

@Test func groupsNeighbouringCoresOfTheSameType() {
    // Two physical "M" clusters of five make one performance level.
    let cores = (0..<10).map { (index: $0, type: "M") } + (10..<15).map { (index: $0, type: "P") }
    let grouped = CPUTopology.contiguousRuns(of: cores)

    #expect(grouped.count == 2)
    #expect(grouped[0].coreIndices == Array(0..<10))
    #expect(grouped[1].coreIndices == Array(10..<15))
}

@Test func realMachineTopologyCoversEveryCore() {
    let host = HostInfo.current()
    guard !host.coreClusters.isEmpty else { return }  // unlabeled is a valid outcome

    let covered = host.coreClusters.flatMap(\.coreIndices).sorted()
    #expect(covered == Array(0..<host.logicalCores))
}
