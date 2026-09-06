import Foundation
import Testing

@testable import CaliperHistory

private let start = Date(timeIntervalSince1970: 1_700_000_000)

/// A full window of buckets, each holding one value.
private func buckets(_ values: [Double], from origin: Date = start) -> [HistorySample] {
    values.enumerated().map { index, value in
        HistorySample(
            series: .cpu,
            timestamp: origin.addingTimeInterval(Double(index * 10)),
            aggregate: Aggregate(value)
        )
    }
}

private func rule(
    _ comparison: AlertComparison = .above,
    threshold: Double = 0.8,
    duration: TimeInterval = 300
) -> AlertRule {
    AlertRule(series: .cpu, comparison: comparison, threshold: threshold, duration: duration)
}

// MARK: - The condition

@Test func aFullWindowOverTheThresholdFires() {
    // Five minutes of ten-second buckets, every one of them over.
    let samples = buckets(Array(repeating: 0.9, count: 30))
    #expect(AlertEvaluator.isFiring(rule(), over: samples, now: start))
}

@Test func oneBucketUnderTheThresholdIsEnoughToNotFire() {
    var values = Array(repeating: 0.9, count: 30)
    values[17] = 0.7
    #expect(!AlertEvaluator.isFiring(rule(), over: buckets(values), now: start))
}

@Test func aGapIsNotASatisfiedCondition() {
    // Twenty buckets where thirty are wanted: a Mac asleep for part of the
    // window recorded nothing, and nothing recorded is not "over eighty per
    // cent". Firing on a hole would make every overnight the loudest night of
    // the week.
    #expect(!AlertEvaluator.isFiring(rule(), over: buckets(Array(repeating: 0.9, count: 20)), now: start))
}

@Test func aBucketThatDippedUnderDoesNotCountHoweverItAveraged() {
    // The stored min/max is what makes this answerable: an average of 0.85 over
    // a bucket that touched 0.5 is not five minutes over the threshold.
    let dipped = [
        HistorySample(
            series: .cpu,
            timestamp: start,
            aggregate: Aggregate(minimum: 0.5, average: 0.85, maximum: 1.0)
        )
    ]
    let steady = buckets(Array(repeating: 0.9, count: 29), from: start.addingTimeInterval(10))
    #expect(!AlertEvaluator.isFiring(rule(), over: dipped + steady, now: start))
}

@Test func belowIsTheMirrorAndUsesTheOtherExtreme() {
    let low = buckets(Array(repeating: 0.05, count: 30))
    #expect(AlertEvaluator.isFiring(rule(.below, threshold: 0.1), over: low, now: start))
    // One bucket that touched the threshold from above is enough.
    var values = Array(repeating: 0.05, count: 30)
    values[3] = 0.2
    #expect(!AlertEvaluator.isFiring(rule(.below, threshold: 0.1), over: buckets(values), now: start))
}

@Test func aDisabledRuleNeverFires() {
    var disabled = rule()
    disabled.isEnabled = false
    #expect(!AlertEvaluator.isFiring(disabled, over: buckets(Array(repeating: 0.9, count: 30)), now: start))
}

// MARK: - The window

@Test func theWindowStopsShortOfNowByOneFlush() {
    // The writer batches a minute at a time, so the newest minute of buckets is
    // missing by construction. A rule evaluated up to `now` would see that hole
    // and conclude the condition lapsed, every single pass.
    let now = Date(timeIntervalSince1970: 1_700_003_600)
    let window = AlertEvaluator.window(for: rule(), now: now)
    #expect(window.end == now.addingTimeInterval(-HistoryRecorder.flushInterval))
    #expect(window.start == window.end.addingTimeInterval(-300))
}

// MARK: - Firing on the edge

@Test func aRuleThatHoldsForAnHourAnnouncesOnce() {
    var state = AlertState()
    let holding = rule()
    // Assigned first because `#expect` cannot call a mutating member.
    let first = state.shouldAnnounce(holding, isFiring: true)
    #expect(first)
    var announcedAgain = false
    for _ in 0..<120 where state.shouldAnnounce(holding, isFiring: true) {
        announcedAgain = true
    }
    #expect(!announcedAgain)
    #expect(state.isFiring(holding.id))
}

@Test func aRuleAnnouncesAgainOnlyAfterItHasCleared() {
    var state = AlertState()
    let holding = rule()
    let first = state.shouldAnnounce(holding, isFiring: true)
    let whileClearing = state.shouldAnnounce(holding, isFiring: false)
    let cleared = state.isFiring(holding.id)
    let second = state.shouldAnnounce(holding, isFiring: true)
    #expect(first)
    #expect(!whileClearing)
    #expect(!cleared)
    #expect(second)
}

@Test func anEditedRuleIsArmedAgain() {
    var state = AlertState()
    let holding = rule()
    let first = state.shouldAnnounce(holding, isFiring: true)
    // Raising a threshold past a firing condition must not leave it silent
    // until it clears at the old one.
    state.forget(holding.id)
    let afterEdit = state.shouldAnnounce(holding, isFiring: true)
    #expect(first)
    #expect(afterEdit)
}
