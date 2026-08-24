import Testing

@testable import CaliperCore

@Test func liveMetricsRunAtTheBaseRateWheneverAnythingIsVisible() {
    for level in ActivityLevel.allCases where level != .hidden {
        #expect(CadenceTable.interval(for: .cpu, at: level) == 1)
        #expect(CadenceTable.interval(for: .network, at: level) == 1)
    }
    #expect(CadenceTable.interval(for: .cpu, at: .hidden) == 5)
}

@Test func expensiveMetricsBackOffWhenNothingIsOnScreen() {
    for kind in [MetricKind.volumes, .connection, .processes, .selfMetrics] {
        let hidden = CadenceTable.interval(for: kind, at: .hidden)
        let menuBar = CadenceTable.interval(for: kind, at: .menuBarOnly)
        let panel = CadenceTable.interval(for: kind, at: .panelOpen)

        #expect(hidden > menuBar, "\(kind) should sample less often while hidden")
        #expect(menuBar >= panel, "\(kind) should sample at least as often with a panel open")
    }
}

@Test func everyIntervalIsAWholeNumberOfBaseTicks() {
    for kind in MetricKind.allCases {
        for level in ActivityLevel.allCases {
            #expect(CadenceTable.interval(for: kind, at: level) >= 1)
        }
    }
}

@Test func metricsAreDueOnMultiplesOfTheirInterval() {
    #expect(CadenceTable.interval(for: .processes, at: .panelOpen) == 3)

    let due = (1...9).filter { CadenceTable.isDue(.processes, tick: UInt64($0), at: .panelOpen) }
    #expect(due == [3, 6, 9])
}
