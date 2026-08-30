import Darwin

@testable import CaliperCore

/// Growth of this process's footprint across one run of `body`, retried up to
/// `attempts` times and reporting the smallest round.
///
/// Tests run in parallel, so a single round charges whatever the neighbouring
/// suites allocated to this one — observed at 2–4 MB against a 2 MB budget,
/// which is a failed test with no leak in it. A real unbalanced retain grows
/// every round; a neighbour's burst does not.
func footprintGrowth(under budget: Int64, attempts: Int = 3, _ body: () -> Void) -> Int64 {
    var smallest = Int64.max
    for _ in 0..<attempts {
        guard let start = ResourceUsage.counters(for: getpid()) else { return .max }
        body()
        guard let end = ResourceUsage.counters(for: getpid()) else { return .max }
        smallest = min(smallest, Int64(end.physicalFootprint) - Int64(start.physicalFootprint))
        if smallest < budget { break }
    }
    return smallest
}
