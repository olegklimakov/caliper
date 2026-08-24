import Testing

@testable import CaliperCore

@Test func everyTickPublishesASnapshot() async {
    let coordinator = SamplingCoordinator()
    let stream = await coordinator.snapshots()
    var snapshots = stream.makeAsyncIterator()

    await coordinator.tick()

    let snapshot = await snapshots.next()
    #expect(snapshot?.host == HostInfo.current())
}

@Test func everySubscriberSeesTheSameTick() async {
    let coordinator = SamplingCoordinator()
    var first = await coordinator.snapshots().makeAsyncIterator()
    var second = await coordinator.snapshots().makeAsyncIterator()

    await coordinator.tick()

    let a = await first.next()
    let b = await second.next()
    #expect(a?.timestamp == b?.timestamp)
}

@Test func cadenceFollowsTheCurrentActivityLevel() async {
    let coordinator = SamplingCoordinator(activityLevel: .panelOpen)

    await coordinator.tick()
    await coordinator.tick()
    await coordinator.tick()
    #expect(await coordinator.isDue(.processes))  // third tick, interval 3

    await coordinator.setActivityLevel(.hidden)
    #expect(await coordinator.isDue(.processes) == false)  // interval 30
}
