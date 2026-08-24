import Foundation
import Testing

@testable import CaliperHistory

/// The overview reads several series and puts one cursor through all of them,
/// so what matters is that the buckets line up and that a series with nothing
/// recorded reads as a gap rather than as a number borrowed from its neighbour.

/// Rows of a tier, written for whichever series are asked for.
private func write(
    _ store: HistoryStore,
    series: [MetricSeries],
    buckets: Int,
    from start: Date,
    tier: HistoryTier = .tenSeconds
) throws {
    var samples: [HistorySample] = []
    for bucket in 0..<buckets {
        let timestamp = start.addingTimeInterval(Double(bucket * tier.seconds))
        for series in series {
            samples.append(
                HistorySample(
                    series: series,
                    timestamp: timestamp,
                    aggregate: Aggregate(
                        minimum: Double(bucket),
                        average: Double(bucket) + 0.5,
                        maximum: Double(bucket) + 1
                    )
                )
            )
        }
    }
    try store.write(samples, tier: tier)
}

@Test func aSliceReadsEverySeriesOnTheSameBuckets() async throws {
    try await withStore { store in
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        try write(store, series: [.cpu, .memory, .temperature], buckets: 6, from: start)

        let slice = try store.slice(
            [.cpu, .memory, .temperature],
            tier: .tenSeconds,
            from: start,
            to: start.addingTimeInterval(60)
        )

        #expect(!slice.isEmpty)
        #expect(slice[.cpu].map(\.timestamp) == slice[.memory].map(\.timestamp))
        #expect(slice[.temperature].count == 6)
        // Oldest first, which the view relies on and the primary key's own
        // order gives for free.
        #expect(slice[.cpu] == slice[.cpu].sorted { $0.timestamp < $1.timestamp })
    }
}

@Test func aSeriesThatWasNeverRecordedReadsEmptyRatherThanMissing() async throws {
    try await withStore { store in
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        try write(store, series: [.cpu], buckets: 3, from: start)

        let slice = try store.slice(
            [.cpu, .temperature],
            tier: .tenSeconds,
            from: start,
            to: start.addingTimeInterval(60)
        )

        #expect(slice[.cpu].count == 3)
        // A machine whose sensors this build cannot read has no temperature
        // history, and the view must be able to say so without a special case.
        #expect(slice[.temperature].isEmpty)
    }
}

@Test func aCursorSnapsToTheBucketHoldingThatMoment() async throws {
    try await withStore { store in
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        try write(store, series: [.cpu], buckets: 6, from: start)

        let slice = try store.slice(
            [.cpu],
            tier: .tenSeconds,
            from: start,
            to: start.addingTimeInterval(60)
        )

        // Seven seconds into the third bucket still reads the third bucket.
        let moment = start.addingTimeInterval(27)
        let bucket = slice.bucket(containing: moment)
        #expect(bucket == start.addingTimeInterval(20))
        #expect(slice.sample(.cpu, at: bucket)?.aggregate.minimum == 2)
    }
}

@Test func aBucketWithNoRowIsAGapAndNotTheNeighbouringValue() async throws {
    try await withStore { store in
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        // Two runs with the Mac asleep between them: buckets 0–1, then 4–5.
        try write(store, series: [.cpu], buckets: 2, from: start)
        try write(store, series: [.cpu], buckets: 2, from: start.addingTimeInterval(40))

        let slice = try store.slice(
            [.cpu],
            tier: .tenSeconds,
            from: start,
            to: start.addingTimeInterval(60)
        )

        #expect(slice.sample(.cpu, at: start.addingTimeInterval(10)) != nil)
        #expect(slice.sample(.cpu, at: start.addingTimeInterval(20)) == nil)
        #expect(slice.sample(.cpu, at: start.addingTimeInterval(30)) == nil)
        #expect(slice.sample(.cpu, at: start.addingTimeInterval(40)) != nil)
        // Past both ends of the stored range, where a binary search is easiest
        // to get wrong.
        #expect(slice.sample(.cpu, at: start.addingTimeInterval(-10)) == nil)
        #expect(slice.sample(.cpu, at: start.addingTimeInterval(120)) == nil)
    }
}

@Test func askingForNoSeriesAsksTheStoreNothing() async throws {
    try await withStore { store in
        let slice = try store.slice([], tier: .tenSeconds, from: .distantPast, to: .distantFuture)
        #expect(slice.isEmpty)
        #expect(slice[.cpu].isEmpty)
    }
}

// MARK: - Stepping the cursor a key at a time

/// Six ten-second buckets, with rows only where the test says: stepping is
/// arithmetic on the tier and the range, and where the rows are only decides
/// where the *first* press lands.
private func sixBuckets(from start: Date, recorded: [Int] = []) -> HistorySlice {
    HistorySlice(
        tier: .tenSeconds,
        start: start,
        end: start.addingTimeInterval(50),
        rows: [
            .cpu: recorded.map { bucket in
                HistorySample(
                    series: .cpu,
                    timestamp: start.addingTimeInterval(Double(bucket * 10)),
                    aggregate: Aggregate(0.5)
                )
            }
        ]
    )
}

@Test func theFirstArrowPressLandsOnTheNewestBucketThatHasSomethingInIt() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    // The recorder flushes once a minute, so the bucket at the right-hand edge
    // is usually still filling. A first press landing there would read "—" and
    // look broken.
    let slice = sixBuckets(from: start, recorded: [0, 1, 2, 3])
    #expect(slice.bucket(from: nil, steppedBy: 1) == start.addingTimeInterval(30))
    #expect(slice.bucket(from: nil, steppedBy: -1) == start.addingTimeInterval(30))
}

@Test func theFirstPressFallsBackToTheEdgeWhenNothingIsRecorded() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    #expect(sixBuckets(from: start).bucket(from: nil, steppedBy: 1) == start.addingTimeInterval(50))
}

@Test func steppingMovesOneBucketAtATime() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let slice = sixBuckets(from: start)
    let middle = start.addingTimeInterval(20)
    #expect(slice.bucket(from: middle, steppedBy: 1) == start.addingTimeInterval(30))
    #expect(slice.bucket(from: middle, steppedBy: -1) == start.addingTimeInterval(10))
}

@Test func steppingStopsAtEitherEndRatherThanWalkingOffTheAxis() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let slice = sixBuckets(from: start)
    #expect(slice.bucket(from: start, steppedBy: -1) == start)
    #expect(slice.bucket(from: start.addingTimeInterval(50), steppedBy: 1) == start.addingTimeInterval(50))
    // Holding the key down is many presses, not one big one.
    #expect(slice.bucket(from: start, steppedBy: -100) == start)
}

@Test func theLeftClampLandsOnABucketThatIsActuallyInsideTheSlice() {
    // A real slice starts at "now minus the span" and is therefore almost never
    // aligned. The bug this guards against: clamping to the bucket *containing*
    // that moment puts the cursor before the slice begins, the view rejects it
    // as out of range, and the rule vanishes instead of parking at the edge.
    let start = Date(timeIntervalSince1970: 1_700_000_003)
    let slice = HistorySlice(
        tier: .tenSeconds,
        start: start,
        end: start.addingTimeInterval(50),
        rows: [:]
    )
    let clamped = try! #require(slice.bucket(from: start.addingTimeInterval(7), steppedBy: -5))
    #expect(clamped >= slice.start)
    #expect(slice.cursorRange?.contains(clamped) == true)
    #expect(clamped == Date(timeIntervalSince1970: 1_700_000_010))
}

@Test func aSpanNarrowerThanOneBucketHasNowhereForACursorToGo() {
    let start = Date(timeIntervalSince1970: 1_700_000_003)
    let slice = HistorySlice(
        tier: .tenSeconds,
        start: start,
        end: start.addingTimeInterval(4),
        rows: [:]
    )
    #expect(slice.cursorRange == nil)
    #expect(slice.bucket(from: nil, steppedBy: 1) == nil)
}

@Test func aStepLandsInABucketTheMacSleptThroughRatherThanSkippingIt() async throws {
    try await withStore { store in
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        // Two buckets, then a four-bucket gap, then one more.
        try write(store, series: [.cpu], buckets: 2, from: start)
        try write(store, series: [.cpu], buckets: 1, from: start.addingTimeInterval(60))

        let slice = try store.slice([.cpu], tier: .tenSeconds, from: start, to: start.addingTimeInterval(60))
        let intoTheGap = try #require(slice.bucket(from: start.addingTimeInterval(10), steppedBy: 1))

        // The night was as long as it was: the cursor lands inside it and the
        // readout says "—", rather than the gap being redrawn as shorter by
        // jumping to the next bucket that happens to hold a row.
        #expect(intoTheGap == start.addingTimeInterval(20))
        #expect(slice.sample(.cpu, at: intoTheGap) == nil)
    }
}
