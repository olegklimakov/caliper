import Foundation
import Testing

@testable import CaliperHistory

/// A minute boundary, so six ten-second buckets roll into exactly one minute.
private let minuteStart = Date(timeIntervalSince1970: 1_700_000_040)

private func tenSecondBuckets(
    from start: Date,
    values: [(minimum: Double, average: Double, maximum: Double, count: Int)]
) -> [HistorySample] {
    values.enumerated().map { index, value in
        HistorySample(
            series: .cpu,
            timestamp: start.addingTimeInterval(Double(index * 10)),
            aggregate: Aggregate(
                minimum: value.minimum,
                average: value.average,
                maximum: value.maximum,
                count: value.count
            )
        )
    }
}

@Test func rollsSixTenSecondBucketsIntoOneMinute() async throws {
    try await withStore { store in
        try store.write(
            tenSecondBuckets(
                from: minuteStart,
                values: (0..<6).map { (Double($0), Double($0) + 0.5, Double($0) + 1, 10) }
            ),
            tier: .tenSeconds
        )

        try await Downsampler(store: store).compact(now: minuteStart.addingTimeInterval(3600))

        let rolled = try store.samples(.cpu, tier: .minute, from: .distantPast, to: .distantFuture)
        #expect(rolled.count == 1)
        #expect(rolled[0].timestamp == minuteStart)
        #expect(rolled[0].aggregate.minimum == 0)
        #expect(rolled[0].aggregate.maximum == 6)
        #expect(abs(rolled[0].aggregate.average - 3.0) < 0.0001)
        // Sixty readings went into the minute, and the count says so — that is
        // what lets it be rolled up again correctly.
        #expect(rolled[0].aggregate.count == 60)
    }
}

@Test func weightsTheAverageByHowManyReadingsEachBucketHeld() async throws {
    try await withStore { store in
        // One bucket with a single reading of 1.0, one with nine of 0.0. The
        // mean of means would be 0.5; the true mean is 0.1.
        try store.write(
            tenSecondBuckets(from: minuteStart, values: [(1, 1, 1, 1), (0, 0, 0, 9)]),
            tier: .tenSeconds
        )

        try await Downsampler(store: store).compact(now: minuteStart.addingTimeInterval(3600))

        let rolled = try store.samples(.cpu, tier: .minute, from: .distantPast, to: .distantFuture)
        #expect(abs((rolled.first?.aggregate.average ?? 0) - 0.1) < 0.0001)
    }
}

@Test func leavesTheBucketThatIsStillFillingAlone() async throws {
    try await withStore { store in
        let minute = Date(timeIntervalSince1970: 1_700_000_060)
        try store.write(
            [.init(series: .cpu, timestamp: minute, aggregate: .init(0.5))],
            tier: .tenSeconds
        )

        // "Now" is inside that same minute, so it has not finished.
        try await Downsampler(store: store).compact(now: minute.addingTimeInterval(30))

        let rolled = try store.rowCount(tier: .minute)
        #expect(rolled == 0)
    }
}

@Test func retentionDropsRowsPastEachTiersHorizon() async throws {
    try await withStore { store in
        let now = Date(timeIntervalSince1970: 1_700_000_040)
        let old = now.addingTimeInterval(-HistoryTier.tenSeconds.retention - 3600)

        try store.write(
            [.init(series: .cpu, timestamp: old, aggregate: .init(0.4))], tier: .tenSeconds)
        try store.write(
            [.init(series: .cpu, timestamp: now, aggregate: .init(0.4))], tier: .tenSeconds)

        try await Downsampler(store: store).compact(now: now)

        let remaining = try store.samples(
            .cpu, tier: .tenSeconds, from: .distantPast, to: .distantFuture)
        #expect(remaining.count == 1)
        #expect(remaining[0].timestamp == now)
    }
}

/// The bug this guards against: deleting expired ten-second rows in the same
/// pass that should have rolled them into minutes, which silently throws away
/// the day that just aged out.
@Test func rollsExpiringRowsUpBeforeDeletingThem() async throws {
    try await withStore { store in
        let now = Date(timeIntervalSince1970: 1_700_000_040)
        let expiring = now.addingTimeInterval(-HistoryTier.tenSeconds.retention - 60)

        try store.write(
            [.init(series: .cpu, timestamp: expiring, aggregate: .init(0.42))],
            tier: .tenSeconds
        )

        try await Downsampler(store: store).compact(now: now)

        // Gone from the fine tier...
        let fine = try store.samples(.cpu, tier: .tenSeconds, from: .distantPast, to: .distantFuture)
        #expect(fine.isEmpty)
        // ...but preserved in the coarser one.
        let minutes = try store.samples(.cpu, tier: .minute, from: .distantPast, to: .distantFuture)
        #expect(minutes.count == 1)
        #expect(abs((minutes.first?.aggregate.average ?? 0) - 0.42) < 0.0001)
    }
}

@Test func compactingTwiceLeavesTheSameNumbers() async throws {
    try await withStore { store in
        // Distinct values, so a second pass that re-aggregated or re-merged
        // would visibly change the result rather than hide behind equal ones.
        let values: [(minimum: Double, average: Double, maximum: Double, count: Int)] =
            (0..<6).map { index in
                let value = Double(index) * 0.1
                return (minimum: value, average: value, maximum: value, count: 10)
            }
        try store.write(tenSecondBuckets(from: minuteStart, values: values), tier: .tenSeconds)

        let downsampler = Downsampler(store: store)
        try await downsampler.compact(now: minuteStart.addingTimeInterval(3600))
        let first = try store.samples(.cpu, tier: .minute, from: .distantPast, to: .distantFuture)

        try await downsampler.compact(now: minuteStart.addingTimeInterval(3600))
        let second = try store.samples(.cpu, tier: .minute, from: .distantPast, to: .distantFuture)

        #expect(first == second)
        #expect(second.count == 1)
    }
}

@Test func bucketsAreAlignedToAbsoluteTime() {
    let date = Date(timeIntervalSince1970: 1_700_000_037)
    #expect(
        HistoryTier.tenSeconds.bucketStart(of: date)
            == Date(timeIntervalSince1970: 1_700_000_030)
    )
    // 1_700_000_037 is 22:13:57 UTC, so its minute starts at 22:13:00.
    #expect(
        HistoryTier.minute.bucketStart(of: date)
            == Date(timeIntervalSince1970: 1_699_999_980)
    )
}

@Test func accumulatorKeepsExtremesAndMean() {
    var accumulator = Accumulator()
    #expect(accumulator.aggregate == nil)

    for value in [0.2, 0.8, 0.5] {
        accumulator.add(value)
    }
    accumulator.add(.nan)  // A missing reading must not poison the bucket.

    let aggregate = accumulator.aggregate
    #expect(aggregate?.minimum == 0.2)
    #expect(aggregate?.maximum == 0.8)
    #expect(abs((aggregate?.average ?? 0) - 0.5) < 0.0001)
    #expect(aggregate?.count == 3)
}

@Test func discardingLeavesNothingToBeWrittenBackAfterAClear() async throws {
    try await withStore { store in
        let recorder = HistoryRecorder(store: store)
        recorder.record([.cpu: 0.5], at: minuteStart)
        // What the settings screen's clear needs: emptying the tables while the
        // recorder holds a bucket would put part of the record straight back.
        recorder.discardPending()
        try recorder.flushNow()
        #expect(try store.rowCount(tier: .tenSeconds) == 0)
    }
}

// MARK: - Sources that arrive after the bucket was built

@Test func aFineRowThatArrivesLateIsFoldedIntoItsBucket() async throws {
    try await withStore { store in
        // Half a minute recorded, compacted, and then the app comes back and
        // writes the rest of it. This is what a relaunch or a wake looks like
        // from the store's side, and six days of real recording found 32
        // ten-minute buckets frozen this way — off by up to seven points of CPU
        // because `DO NOTHING` locked the late rows out for good.
        try store.write(
            tenSecondBuckets(from: minuteStart, values: Array(repeating: (0.2, 0.2, 0.2, 10), count: 3)),
            tier: .tenSeconds
        )
        let downsampler = Downsampler(store: store)
        let now = minuteStart.addingTimeInterval(120)
        try await downsampler.compact(now: now)

        let early = try #require(try store.samples(.cpu, tier: .minute, from: minuteStart, to: now).first)
        #expect(early.aggregate.count == 30)

        try store.write(
            tenSecondBuckets(
                from: minuteStart.addingTimeInterval(30),
                values: Array(repeating: (0.8, 0.8, 0.8, 10), count: 3)
            ),
            tier: .tenSeconds
        )
        try await downsampler.compact(now: now)

        let healed = try #require(try store.samples(.cpu, tier: .minute, from: minuteStart, to: now).first)
        #expect(healed.aggregate.count == 60)
        #expect(abs(healed.aggregate.average - 0.5) < 0.0001)
        #expect(abs(healed.aggregate.maximum - 0.8) < 0.0001)
    }
}

@Test func aBucketOlderThanTheRebuildWindowIsLeftAlone() async throws {
    try await withStore { store in
        try store.write(
            tenSecondBuckets(from: minuteStart, values: Array(repeating: (0.2, 0.2, 0.2, 10), count: 3)),
            tier: .tenSeconds
        )
        let downsampler = Downsampler(store: store)
        try await downsampler.compact(now: minuteStart.addingTimeInterval(120))

        // A day later, the rest of that minute somehow appears. It is not
        // rebuilt: past the window a bucket is settled, and the window is kept
        // shorter than the shortest source retention precisely so that nothing
        // is ever recomputed from rows that have partly aged out.
        try store.write(
            tenSecondBuckets(
                from: minuteStart.addingTimeInterval(30),
                values: Array(repeating: (0.8, 0.8, 0.8, 10), count: 3)
            ),
            tier: .tenSeconds
        )
        let muchLater = minuteStart.addingTimeInterval(Downsampler.rebuildWindow + 3600)
        try await downsampler.compact(now: muchLater)

        let settled = try #require(
            try store.samples(.cpu, tier: .minute, from: minuteStart, to: muchLater).first)
        #expect(settled.aggregate.count == 30)
    }
}
