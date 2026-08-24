import Testing

@testable import CaliperCore

@Test func theFirstCPUSampleOnlySeedsTheBaseline() {
    var sampler = CPUSampler()
    #expect(sampler.sample(clusters: []) == nil)
    #expect(sampler.sample(clusters: []) != nil)
}

@Test func cpuLoadStaysWithinAFraction() {
    let host = HostInfo.current()
    var sampler = CPUSampler()
    _ = sampler.sample(clusters: host.coreClusters)

    guard let sample = sampler.sample(clusters: host.coreClusters) else {
        Issue.record("second sample should produce a reading")
        return
    }

    #expect(sample.cores.count == host.logicalCores)
    #expect(sample.clusters.count == host.coreClusters.count)
    #expect((0...1).contains(sample.total))
    #expect(sample.cores.allSatisfy { (0...1).contains($0) })
    #expect(sample.loadAverage.oneMinute >= 0)
}

@Test func resettingTheBaselineSkipsTheNextInterval() {
    var sampler = CPUSampler()
    _ = sampler.sample(clusters: [])
    #expect(sampler.sample(clusters: []) != nil)

    sampler.resetBaseline()
    #expect(sampler.sample(clusters: []) == nil)
}

@Test func memoryAddsUpToTheInstalledTotal() {
    let host = HostInfo.current()
    guard let sample = MemorySampler().sample(totalMemory: host.physicalMemory) else {
        Issue.record("memory sampling should work on every supported machine")
        return
    }

    #expect(sample.total == host.physicalMemory)
    #expect(sample.used > 0)
    #expect(sample.used < sample.total)
    // Used, cached and free are the whole of physical memory, give or take the
    // pages that change between the reads inside one host_statistics64 call.
    let accounted = Double(sample.used &+ sample.cached &+ sample.free)
    #expect(abs(accounted - Double(sample.total)) / Double(sample.total) < 0.1)
    #expect(sample.swapUsed <= sample.swapTotal)
    // The split the panel draws has to close exactly, whatever the page
    // counters leave unaccounted for: a bar drawn from these two numbers fills
    // its width, and the legend beside it adds up to the installed memory.
    #expect(sample.used &+ sample.available == sample.total)
}
