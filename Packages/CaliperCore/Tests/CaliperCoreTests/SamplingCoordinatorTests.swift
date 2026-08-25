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

@Test func cadenceFollowsWhatIsBeingDrawn() async {
    let coordinator = SamplingCoordinator(
        demand: MetricDemand(isVisible: true, metrics: [.processes])
    )

    await coordinator.tick()
    await coordinator.tick()
    await coordinator.tick()
    #expect(await coordinator.isDue(.processes))  // third tick, interval 3

    coordinator.setDemand(.hidden)
    #expect(await coordinator.isDue(.processes) == false)  // interval 30
}

/// The demand is read at the tick, not carried onto the actor by a task of its
/// own — so a change made while a tick is in flight lands whole, and two
/// changes in quick succession cannot be applied in the order they were not
/// made in.
@Test func demandTakesEffectWithoutAwaiting() async {
    let coordinator = SamplingCoordinator(demand: .hidden)

    coordinator.setDemand(.everything)

    await coordinator.tick()
    await coordinator.tick()
    #expect(await coordinator.isDue(.sensors))  // second tick, interval 2
}
