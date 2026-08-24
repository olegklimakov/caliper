import Foundation
import Testing

@testable import CaliperCore

@Test func hostInfoReportsTheRunningMachine() {
    let host = HostInfo.current()

    #expect(host.logicalCores == ProcessInfo.processInfo.processorCount)
    #expect(host.physicalMemory == ProcessInfo.processInfo.physicalMemory)
    #expect(host.chip != "unknown")
    // Machines whose layout cannot be established report no clusters at all;
    // when they do report them, the clusters must cover every logical core.
    if !host.coreClusters.isEmpty {
        #expect(host.coreClusters.reduce(0) { $0 + $1.logicalCores } == host.logicalCores)
    }
}

@Test func snapshotJSONRoundTrips() async throws {
    let coordinator = SamplingCoordinator()
    await coordinator.tick()
    await coordinator.tick()
    let snapshot = await coordinator.latestSnapshot()

    let json = try snapshot.jsonRepresentation()
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(SystemSnapshot.self, from: Data(json.utf8))

    #expect(decoded.host == snapshot.host)
    #expect(decoded.cpu == snapshot.cpu)
    #expect(decoded.memory == snapshot.memory)
    // ISO-8601 encoding drops sub-second precision.
    #expect(abs(decoded.timestamp.timeIntervalSince(snapshot.timestamp)) < 1)
}
