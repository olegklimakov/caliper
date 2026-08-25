import Testing

@testable import CaliperCore

@Test func liveMetricsRunAtTheBaseRateWheneverAnythingIsVisible() {
    // The four cheapest sweeps are also what the ten-second history buckets
    // fold, so they run at the base rate whether or not anything draws them.
    for demand in [MetricDemand.menuBar, .everything, MetricDemand(isVisible: true, metrics: [])] {
        #expect(CadenceTable.interval(for: .cpu, demand: demand) == 1)
        #expect(CadenceTable.interval(for: .network, demand: demand) == 1)
    }
    #expect(CadenceTable.interval(for: .cpu, demand: .hidden) == 5)
}

@Test func expensiveMetricsBackOffWhenNobodyIsDrawingThem() {
    for kind in [MetricKind.volumes, .connection, .processes, .sensors] {
        let hidden = CadenceTable.interval(for: kind, demand: .hidden)
        let background = CadenceTable.interval(for: kind, demand: .menuBar)
        let foreground = CadenceTable.interval(for: kind, demand: .everything)

        #expect(hidden > background, "\(kind) should sample less often while hidden")
        #expect(background > foreground, "\(kind) should sample more often while drawn")
    }
}

/// The point of the whole mechanism: a panel that draws no temperature must not
/// pay for the sensor sweep, which is the most expensive read in the app.
@Test func aPanelPaysOnlyForWhatItDraws() {
    let cpuPanel = MetricDemand(isVisible: true, metrics: [.cpu, .processes])
    let sensorsPanel = MetricDemand(isVisible: true, metrics: [.sensors])

    #expect(CadenceTable.interval(for: .sensors, demand: cpuPanel) == 30)
    #expect(CadenceTable.interval(for: .sensors, demand: sensorsPanel) == 2)

    #expect(CadenceTable.interval(for: .processes, demand: cpuPanel) == 3)
    #expect(CadenceTable.interval(for: .processes, demand: sensorsPanel) == 10)
}

@Test func everyIntervalIsAWholeNumberOfBaseTicks() {
    let demands: [MetricDemand] = [.hidden, .menuBar, .everything]
    for kind in MetricKind.allCases {
        for demand in demands {
            #expect(CadenceTable.interval(for: kind, demand: demand) >= 1)
        }
    }
}

@Test func metricsAreDueOnMultiplesOfTheirInterval() {
    #expect(CadenceTable.interval(for: .processes, demand: .everything) == 3)

    let due = (1...9).filter {
        CadenceTable.isDue(.processes, tick: UInt64($0), demand: .everything)
    }
    #expect(due == [3, 6, 9])
}

/// A metric nobody is drawing still samples — the history has to have something
/// to fold — just not at the rate of one being watched.
@Test func anUndrawnMetricStillSamples() {
    for kind in MetricKind.allCases {
        #expect(CadenceTable.interval(for: kind, demand: .menuBar) >= 1)
    }
    #expect(CadenceTable.isDue(.sensors, tick: 30, demand: .menuBar))
}

/// A display that has gone to sleep outranks whatever was left open on it.
@Test func nothingRunsAtFullRateWhileTheDisplayIsAsleep() {
    let asleepWithAPanelOpen = MetricDemand(isVisible: false, metrics: [.sensors])

    #expect(CadenceTable.interval(for: .sensors, demand: asleepWithAPanelOpen) == 60)
}
