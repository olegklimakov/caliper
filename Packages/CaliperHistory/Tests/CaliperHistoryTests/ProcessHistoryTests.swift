import Foundation
import GRDB
import CaliperCore
import Testing

@testable import CaliperHistory

/// A thirty-second boundary, so two buckets roll into exactly one minute.
private let bucketStart = Date(timeIntervalSince1970: 1_700_000_040)

private func process(
    _ name: String,
    cpu: Double = 0,
    footprint: UInt64 = 0,
    disk: Double = 0
) -> ProcessSample {
    ProcessSample(
        pid: 1,
        name: name,
        cpu: cpu,
        memoryFootprint: footprint,
        diskRate: disk,
        power: 0,
        wakeupsPerSecond: 0,
        performanceCycleShare: nil,
        qos: nil
    )
}

private func sweep(at date: Date, _ samples: [ProcessSample]) -> ProcessesSample {
    ProcessesSample(
        sampledAt: date,
        topByCPU: samples.sorted { $0.cpu > $1.cpu },
        topByMemory: samples.sorted { $0.memoryFootprint > $1.memoryFootprint },
        topByDisk: samples.filter { $0.diskRate > 0 },
        topByPower: [],
        unreadableCount: 0
    )
}

private let megabyte: UInt64 = 1_048_576

// MARK: - Recorder

@Test func foldsMeanCPUAndPeakFootprintOverABucket() async throws {
    try await withStore { store in
        let recorder = ProcessHistoryRecorder(store: store, isEnabled: true)
        recorder.record(sweep(at: bucketStart, [process("kernel_task", cpu: 0.2, footprint: 100 * megabyte)]))
        recorder.record(
            sweep(at: bucketStart.addingTimeInterval(10), [process("kernel_task", cpu: 0.6, footprint: 300 * megabyte)])
        )
        try recorder.flushNow()

        let bucket = try await store.consumers(at: bucketStart, tier: .thirtySeconds)
        #expect(bucket.consumers.count == 1)
        let usage = try #require(bucket.consumers.first)
        // The mean of 0.2 and 0.6, not the last reading.
        #expect(abs(usage.cpu - 0.4) < 0.001)
        // The peak, not the mean: what a process took at worst is the question
        // a memory history is asked.
        #expect(usage.footprint == 300 * megabyte)
    }
}

@Test func ignoresASweepItHasAlreadyFolded() async throws {
    try await withStore { store in
        let recorder = ProcessHistoryRecorder(store: store, isEnabled: true)
        // The bug this guards against: a snapshot carries the newest process
        // sample rather than one taken on its own tick, so the same sweep is
        // delivered again every second. Folding it each time would weight one
        // reading thirtyfold and drag the mean onto it.
        let stale = sweep(at: bucketStart, [process("Xcode", cpu: 1.0)])
        recorder.record(stale)
        for _ in 0..<20 { recorder.record(stale) }
        recorder.record(sweep(at: bucketStart.addingTimeInterval(10), [process("Xcode", cpu: 0.0)]))
        try recorder.flushNow()

        let usage = try #require(try await store.consumers(at: bucketStart, tier: .thirtySeconds).consumers.first)
        #expect(abs(usage.cpu - 0.5) < 0.001)
    }
}

@Test func keepsTheTopTenByCPUUnionedWithTheTopTenByFootprint() async throws {
    try await withStore { store in
        let recorder = ProcessHistoryRecorder(store: store, isEnabled: true)
        // Thirty processes: the CPU order and the footprint order are exact
        // opposites, so ten of each is twenty distinct names and the ten in the
        // middle belong in neither list.
        let samples = (0..<30).map { index in
            process("p\(index)", cpu: Double(30 - index), footprint: UInt64(index + 1) * megabyte)
        }
        recorder.record(sweep(at: bucketStart, samples))
        try recorder.flushNow()

        let names = Set(try await store.consumers(at: bucketStart, tier: .thirtySeconds).consumers.map(\.name))
        #expect(names.count == 20)
        #expect(names.contains("p0"))  // heaviest by CPU
        #expect(names.contains("p29"))  // heaviest by footprint
        #expect(!names.contains("p15"))  // middling at both
    }
}

@Test func aProcessInTwoOfTheSamplersListsIsStillOneReading() async throws {
    try await withStore { store in
        let recorder = ProcessHistoryRecorder(store: store, isEnabled: true)
        // Same process at the top of CPU, memory and disk at once — three
        // appearances in one sweep, which is one reading of one process.
        recorder.record(sweep(at: bucketStart, [process("Safari", cpu: 2.0, footprint: 8 * megabyte, disk: 4096)]))
        try recorder.flushNow()

        let usage = try #require(try await store.consumers(at: bucketStart, tier: .thirtySeconds).consumers.first)
        #expect(abs(usage.cpu - 2.0) < 0.001)
        #expect(abs(usage.diskRate - 4096) < 1)
    }
}

@Test func recordsNothingWhileSwitchedOff() async throws {
    try await withStore { store in
        let recorder = ProcessHistoryRecorder(store: store, isEnabled: false)
        recorder.record(sweep(at: bucketStart, [process("Xcode", cpu: 1.0)]))
        try recorder.flushNow()
        #expect(try store.processRowCount(tier: .thirtySeconds) == 0)

        recorder.setEnabled(true)
        recorder.record(sweep(at: bucketStart, [process("Xcode", cpu: 1.0)]))
        try recorder.flushNow()
        #expect(try store.processRowCount(tier: .thirtySeconds) == 1)
    }
}

@Test func switchingOffDropsTheBucketStillFilling() async throws {
    try await withStore { store in
        let recorder = ProcessHistoryRecorder(store: store, isEnabled: true)
        recorder.record(sweep(at: bucketStart, [process("Xcode", cpu: 1.0)]))
        // Half a bucket recorded before the switch is not something the user
        // agreed to keep.
        recorder.setEnabled(false)
        try recorder.flushNow()
        #expect(try store.processRowCount(tier: .thirtySeconds) == 0)
    }
}

@Test func discardingDropsWhatWouldOtherwiseBeWrittenBack() async throws {
    try await withStore { store in
        let recorder = ProcessHistoryRecorder(store: store, isEnabled: true)
        recorder.record(sweep(at: bucketStart, [process("Xcode", cpu: 1.0)]))
        // What the delete button needs: emptying the tables while the recorder
        // still holds a bucket would put part of the record straight back.
        recorder.discardPending()
        try recorder.flushNow()
        #expect(try store.processRowCount(tier: .thirtySeconds) == 0)
        // And recording carries on afterwards.
        recorder.record(sweep(at: bucketStart.addingTimeInterval(60), [process("Xcode", cpu: 1.0)]))
        try recorder.flushNow()
        #expect(try store.processRowCount(tier: .thirtySeconds) == 1)
    }
}

// MARK: - Store

@Test func aNameIsInternedOnceHoweverManyBucketsUseIt() async throws {
    try await withStore { store in
        let rows = (0..<50).map { index in
            ProcessRow(
                name: "com.apple.WebKit.WebContent",
                timestamp: bucketStart.addingTimeInterval(Double(index * 30)),
                cpuPermille: 100,
                footprintMB: 64,
                diskKBps: 0,
                count: 1
            )
        }
        try store.write(processes: rows, tier: .thirtySeconds)

        #expect(try store.processRowCount(tier: .thirtySeconds) == 50)
        #expect(try store.internedNameCount() == 1)
    }
}

@Test func writingTheSameProcessBucketTwiceMergesTheTwoWrites() async throws {
    try await withStore { store in
        // Quitting and relaunching inside one bucket: two partial readings of
        // the same thirty seconds, which have to land as one row.
        try store.write(
            processes: [ProcessRow(name: "Xcode", timestamp: bucketStart, cpuPermille: 200, footprintMB: 100, diskKBps: 0, count: 1)],
            tier: .thirtySeconds
        )
        try store.write(
            processes: [ProcessRow(name: "Xcode", timestamp: bucketStart, cpuPermille: 600, footprintMB: 400, diskKBps: 0, count: 3)],
            tier: .thirtySeconds
        )

        #expect(try store.processRowCount(tier: .thirtySeconds) == 1)
        let usage = try #require(try await store.consumers(at: bucketStart, tier: .thirtySeconds).consumers.first)
        // Weighted by count: (200×1 + 600×3) / 4 = 500 permille. The mean of
        // means would be 400.
        #expect(abs(usage.cpu - 0.5) < 0.001)
        #expect(usage.footprint == 400 * megabyte)
    }
}

@Test func consumersComeBackHeaviestFirst() async throws {
    try await withStore { store in
        try store.write(
            processes: [
                ProcessRow(name: "quiet", timestamp: bucketStart, cpuPermille: 10, footprintMB: 1, diskKBps: 0, count: 1),
                ProcessRow(name: "busy", timestamp: bucketStart, cpuPermille: 900, footprintMB: 1, diskKBps: 0, count: 1),
                ProcessRow(name: "middling", timestamp: bucketStart, cpuPermille: 300, footprintMB: 1, diskKBps: 0, count: 1),
            ],
            tier: .thirtySeconds
        )

        let bucket = try await store.consumers(at: bucketStart, tier: .thirtySeconds)
        #expect(bucket.consumers.map(\.name) == ["busy", "middling", "quiet"])
        // The readout labels itself with the span it covers, not an instant.
        #expect(bucket.start == bucketStart)
        #expect(bucket.end == bucketStart.addingTimeInterval(30))
    }
}

@Test func aMomentWithNothingRecordedIsAnEmptyBucketRatherThanAnError() async throws {
    try await withStore { store in
        let bucket = try await store.consumers(at: bucketStart, tier: .thirtySeconds)
        #expect(bucket.isEmpty)
    }
}

@Test func aCursorAnywhereInABucketFindsIt() async throws {
    try await withStore { store in
        try store.write(
            processes: [ProcessRow(name: "Xcode", timestamp: bucketStart, cpuPermille: 100, footprintMB: 1, diskKBps: 0, count: 1)],
            tier: .thirtySeconds
        )
        // Twenty-nine seconds in is still the same bucket.
        let bucket = try await store.consumers(at: bucketStart.addingTimeInterval(29), tier: .thirtySeconds)
        #expect(bucket.start == bucketStart)
        #expect(bucket.consumers.count == 1)
    }
}

@Test func deletingProcessHistoryLeavesNeitherRowsNorNames() async throws {
    try await withStore { store in
        try store.write(
            processes: [ProcessRow(name: "Xcode", timestamp: bucketStart, cpuPermille: 100, footprintMB: 1, diskKBps: 0, count: 1)],
            tier: .thirtySeconds
        )
        try store.write(
            processes: [ProcessRow(name: "Safari", timestamp: bucketStart, cpuPermille: 100, footprintMB: 1, diskKBps: 0, count: 1)],
            tier: .minute
        )

        try await store.deleteProcessHistory()

        #expect(try store.processRowCount(tier: .thirtySeconds) == 0)
        #expect(try store.processRowCount(tier: .minute) == 0)
        // The names too: a list of every application that ran is the record
        // being taken back, not just the numbers beside it.
        #expect(try store.internedNameCount() == 0)
    }
}

// MARK: - Rollup and retention

/// Two thirty-second buckets whose top-N sets differ, one minute apart from
/// nothing else.
private func twoDisagreeingBuckets(in store: HistoryStore) throws {
    // First half-minute: `alpha` is busy, `beta` is not there at all.
    try store.write(
            processes:         [
            ProcessRow(name: "alpha", timestamp: bucketStart, cpuPermille: 800, footprintMB: 10, diskKBps: 0, count: 3),
            ProcessRow(name: "gamma", timestamp: bucketStart, cpuPermille: 100, footprintMB: 20, diskKBps: 0, count: 3),
        ],
        tier: .thirtySeconds
    )
    // Second: `beta` appears and `alpha` is gone.
    try store.write(
            processes:         [
            ProcessRow(
                name: "beta", timestamp: bucketStart.addingTimeInterval(30),
                cpuPermille: 400, footprintMB: 30, diskKBps: 0, count: 3),
            ProcessRow(
                name: "gamma", timestamp: bucketStart.addingTimeInterval(30),
                cpuPermille: 300, footprintMB: 20, diskKBps: 0, count: 3),
        ],
        tier: .thirtySeconds
    )
}

@Test func rollsTwoThirtySecondBucketsIntoOneMinuteAndReRanksThem() async throws {
    try await withStore { store in
        try twoDisagreeingBuckets(in: store)
        // Well past both buckets, but inside every retention horizon.
        try await Downsampler(store: store).compact(now: bucketStart.addingTimeInterval(3600))

        let minute = try await store.consumers(at: bucketStart, tier: .minute)
        #expect(minute.start == bucketStart)
        // The union of the two source sets, re-ranked over the minute: alpha's
        // 0.8 beats beta's 0.4 even though alpha was only in one bucket.
        #expect(minute.consumers.map(\.name) == ["alpha", "beta", "gamma"])

        let alpha = try #require(minute.consumers.first)
        // Averaged over the bucket it appeared in, not over both. Absence means
        // "not in the top ten", not "idle", and halving it would be inventing
        // an idle half-minute.
        #expect(abs(alpha.cpu - 0.8) < 0.001)

        let gamma = try #require(minute.consumers.last)
        // In both, so re-weighted across both: (100×3 + 300×3) / 6 = 200.
        #expect(abs(gamma.cpu - 0.2) < 0.001)
    }
}

@Test func compactingProcessesTwiceLeavesTheSameNumbers() async throws {
    try await withStore { store in
        try twoDisagreeingBuckets(in: store)
        let downsampler = Downsampler(store: store)
        let now = bucketStart.addingTimeInterval(3600)

        try await downsampler.compact(now: now)
        let first = try await store.consumers(at: bucketStart, tier: .minute)
        try await downsampler.compact(now: now)
        let second = try await store.consumers(at: bucketStart, tier: .minute)

        #expect(first == second)
    }
}

@Test func processRetentionDropsRowsPastEachHorizon() async throws {
    try await withStore { store in
        try store.write(
            processes: [ProcessRow(name: "alpha", timestamp: bucketStart, cpuPermille: 100, footprintMB: 1, diskKBps: 0, count: 1)],
            tier: .thirtySeconds
        )
        try store.write(
            processes: [ProcessRow(name: "alpha", timestamp: bucketStart, cpuPermille: 100, footprintMB: 1, diskKBps: 0, count: 1)],
            tier: .minute
        )

        // Two days later: past the fine tier's day, inside the week the user
        // chose for the coarse one.
        try await Downsampler(store: store).compact(
            now: bucketStart.addingTimeInterval(2 * 24 * 3600),
            processRetention: ProcessRetention.week.seconds
        )

        #expect(try store.processRowCount(tier: .thirtySeconds) == 0)
        #expect(try store.processRowCount(tier: .minute) == 1)
    }
}

@Test func theSettingIsWhatTheCoarseTierKeeps() async throws {
    try await withStore { store in
        try store.write(
            processes: [ProcessRow(name: "alpha", timestamp: bucketStart, cpuPermille: 100, footprintMB: 1, diskKBps: 0, count: 1)],
            tier: .minute
        )
        // The bug this guards against: clamping every tier to its own default
        // made a fortnight silently mean a week, because the coarse tier's
        // default *is* a week.
        try await Downsampler(store: store).compact(
            now: bucketStart.addingTimeInterval(10 * 24 * 3600),
            processRetention: ProcessRetention.twoWeeks.seconds
        )
        #expect(try store.processRowCount(tier: .minute) == 1)
    }
}

@Test func theReadPicksTheTierTheSweepWouldHaveKept() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    // Ten days back with a fortnight kept: gone from the fine tier, still in
    // the coarse one. The reader and the sweep have to say the same thing, or
    // the pane draws an empty bucket over rows that are still there.
    let moment = now.addingTimeInterval(-10 * 24 * 3600)
    let retention = ProcessRetention.twoWeeks.seconds
    #expect(ProcessTier.holding(moment, retention: retention, now: now) == .minute)
    #expect(ProcessTier.minute.retention(keeping: retention) == retention)
    #expect(ProcessTier.thirtySeconds.retention(keeping: retention) == 24 * 3600)
}

@Test func theFineTierIsCappedAtItsOwnDayHoweverLongTheSettingSays() async throws {
    try await withStore { store in
        try store.write(
            processes: [ProcessRow(name: "alpha", timestamp: bucketStart, cpuPermille: 100, footprintMB: 1, diskKBps: 0, count: 1)],
            tier: .thirtySeconds
        )
        // A fortnight chosen in settings does not buy a fortnight of
        // thirty-second rows: that would be most of the file.
        try await Downsampler(store: store).compact(
            now: bucketStart.addingTimeInterval(2 * 24 * 3600),
            processRetention: ProcessRetention.twoWeeks.seconds
        )
        #expect(try store.processRowCount(tier: .thirtySeconds) == 0)
    }
}

@Test func aNameNoTierReferencesAnyMoreIsCollected() async throws {
    try await withStore { store in
        let now = bucketStart.addingTimeInterval(2 * 24 * 3600)
        try store.write(
            processes: [
                ProcessRow(name: "gone", timestamp: bucketStart, cpuPermille: 100, footprintMB: 1, diskKBps: 0, count: 1)
            ],
            tier: .thirtySeconds
        )
        // Recorded a minute ago, so nothing about it has aged out.
        try store.write(
            processes: [
                ProcessRow(
                    name: "stays", timestamp: now.addingTimeInterval(-60),
                    cpuPermille: 100, footprintMB: 1, diskKBps: 0, count: 1)
            ],
            tier: .thirtySeconds
        )

        // Everything is kept for a day, so the two-day-old rows go — including
        // the minute rows they were rolled up into on the way out.
        try await Downsampler(store: store).compact(now: now, processRetention: ProcessRetention.day.seconds)

        // Otherwise the name table grows forever with every short-lived build
        // script the machine ever ran.
        #expect(try store.internedNameCount() == 1)
        #expect(try await store.consumers(at: bucketStart, tier: .minute).isEmpty)
    }
}

// MARK: - Tiers

@Test func aMomentIsAnsweredByTheFinestTierThatStillHoldsIt() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    #expect(ProcessTier.holding(now.addingTimeInterval(-60), retention: ProcessRetention.week.seconds, now: now) == .thirtySeconds)
    #expect(
        ProcessTier.holding(now.addingTimeInterval(-2 * 24 * 3600), retention: ProcessRetention.week.seconds, now: now)
            == .minute
    )
    // Past what was kept, so there is nothing to show and nothing to query.
    #expect(
        ProcessTier.holding(now.addingTimeInterval(-30 * 24 * 3600), retention: ProcessRetention.week.seconds, now: now)
            == nil
    )
    // A shorter retention makes the coarse tier stop sooner.
    #expect(
        ProcessTier.holding(now.addingTimeInterval(-2 * 24 * 3600), retention: ProcessRetention.day.seconds, now: now)
            == nil
    )
}

// MARK: - Migration

@Test func aStoreRecordedBeforeProcessHistoryGainsItWithoutLosingWhatItHeld() async throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("Caliper-migration-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let url = directory.appendingPathComponent("history.sqlite")
    // A store as an earlier build left it: metric tiers and sample counts, and
    // no idea that processes were ever going to be recorded.
    let queue = try DatabaseQueue(path: url.path)
    try HistoryDatabase.migrator.migrate(queue, upTo: "sample counts")
    let store = HistoryStore(queue: queue)
    try store.write(
        [HistorySample(series: .cpu, timestamp: bucketStart, aggregate: Aggregate(0.5))],
        tier: .tenSeconds
    )

    // Reopening on this build adds the process tables. The rows already there
    // are not what a migration is allowed to cost.
    try HistoryDatabase.migrator.migrate(queue)

    #expect(try store.rowCount(tier: .tenSeconds) == 1)
    try store.write(
        processes: [
            ProcessRow(name: "Xcode", timestamp: bucketStart, cpuPermille: 100, footprintMB: 1, diskKBps: 0, count: 1)
        ],
        tier: .thirtySeconds
    )
    #expect(try await store.consumers(at: bucketStart, tier: .thirtySeconds).consumers.count == 1)
}

@Test func aProcessThatFallsOutOfTheTopTenLeavesTheRebuiltBucket() async throws {
    try await withStore { store in
        // The first half-minute is all `quiet` had to compete with, so it makes
        // the minute's list. Then the rest of the minute arrives and twenty
        // busier processes push it out.
        try store.write(
            processes: [
                ProcessRow(name: "quiet", timestamp: bucketStart, cpuPermille: 10, footprintMB: 1, diskKBps: 0, count: 3)
            ],
            tier: .thirtySeconds
        )
        let downsampler = Downsampler(store: store)
        let now = bucketStart.addingTimeInterval(300)
        try await downsampler.compact(now: now)
        #expect(try await store.consumers(at: bucketStart, tier: .minute).consumers.map(\.name) == ["quiet"])

        try store.write(
            processes: (0..<20).map { index in
                ProcessRow(
                    name: "busy\(index)",
                    timestamp: bucketStart.addingTimeInterval(30),
                    cpuPermille: 1000 + index,
                    footprintMB: 100 + index,
                    diskKBps: 0,
                    count: 3
                )
            },
            tier: .thirtySeconds
        )
        try await downsampler.compact(now: now)

        // An update could only have overwritten `quiet`'s row, never removed
        // it, and the minute would have claimed a process that does not belong
        // in its top ten.
        let names = try await store.consumers(at: bucketStart, tier: .minute).consumers.map(\.name)
        #expect(!names.contains("quiet"))
        // Ten, not twenty: these twenty rank the same way by CPU as by
        // footprint, so the two top-tens are the same ten processes.
        #expect(names.count == ProcessTier.topCount)
    }
}

/// The bucket a cursor is standing in is usually still in memory: the recorder
/// closes one only when a later sweep arrives, and writes on a flush a minute
/// apart, while the ten-second metric tier is seconds behind the clock. So the
/// overview's cursor, resting on the newest metric bucket, asks for a process
/// bucket nobody has written — which is how a Mac that had been recording all
/// day reported "no processes recorded" for the last hour.
@Test func aBucketNotWrittenYetIsAnsweredByTheOneBeforeIt() async throws {
    try await withStore { store in
        try store.write(
            processes: [
                ProcessRow(name: "Xcode", timestamp: bucketStart, cpuPermille: 400, footprintMB: 1, diskKBps: 0, count: 1)
            ],
            tier: .thirtySeconds
        )

        // The next bucket along, which the writer has not reached — and it is
        // the bucket the clock is standing in, which is what makes it reachable.
        let bucket = try await store.consumers(
            at: bucketStart.addingTimeInterval(35),
            tier: .thirtySeconds,
            now: bucketStart.addingTimeInterval(35)
        )

        #expect(bucket.consumers.map(\.name) == ["Xcode"])
        // Labelled with the bucket that answered, not the one that was asked
        // for: the readout says which span it is showing.
        #expect(bucket.start == bucketStart)
    }
}

/// Only as far back as the writer can be behind. Past that the rows describe a
/// different moment than the one asked about, and an empty answer is the
/// truthful one — a Mac asleep for an hour did not have Xcode running in it.
@Test func reachingBackStopsAtTheWritersLag() async throws {
    try await withStore { store in
        try store.write(
            processes: [
                ProcessRow(name: "Xcode", timestamp: bucketStart, cpuPermille: 400, footprintMB: 1, diskKBps: 0, count: 1)
            ],
            tier: .thirtySeconds
        )

        let long = try await store.consumers(
            at: bucketStart.addingTimeInterval(600),
            tier: .thirtySeconds,
            now: bucketStart.addingTimeInterval(600)
        )

        #expect(long.isEmpty)
    }
}

/// One bucket plus one flush interval, exactly: the furthest the writer can be
/// behind, and therefore the furthest an answer may come from.
@Test func theReachIsOneBucketAndOneFlush() async throws {
    try await withStore { store in
        try store.write(
            processes: [
                ProcessRow(name: "Xcode", timestamp: bucketStart, cpuPermille: 400, footprintMB: 1, diskKBps: 0, count: 1)
            ],
            tier: .thirtySeconds
        )
        let reach = Double(ProcessTier.thirtySeconds.seconds) + ProcessTier.flushInterval

        let atLimit = try await store.consumers(
            at: bucketStart.addingTimeInterval(reach),
            tier: .thirtySeconds,
            now: bucketStart.addingTimeInterval(reach)
        )
        let pastLimit = try await store.consumers(
            at: bucketStart.addingTimeInterval(reach + Double(ProcessTier.thirtySeconds.seconds)),
            tier: .thirtySeconds,
            now: bucketStart.addingTimeInterval(reach + Double(ProcessTier.thirtySeconds.seconds))
        )

        #expect(atLimit.consumers.count == 1)
        #expect(pastLimit.isEmpty)
    }
}

/// Reaching back is for the bucket the writer has not caught up with, and for
/// no other. An empty bucket in the middle of a night the Mac spent asleep is
/// empty, and answering it with readings from a minute earlier would put a list
/// of processes beside a metric row that reads "—".
@Test func anOldEmptyBucketIsNotAnsweredByAnEarlierOne() async throws {
    try await withStore { store in
        try store.write(
            processes: [
                ProcessRow(name: "Xcode", timestamp: bucketStart, cpuPermille: 400, footprintMB: 1, diskKBps: 0, count: 1)
            ],
            tier: .thirtySeconds
        )

        // The bucket right after the written one — reachable at the head, but
        // this is hours later.
        let bucket = try await store.consumers(
            at: bucketStart.addingTimeInterval(35),
            tier: .thirtySeconds,
            now: bucketStart.addingTimeInterval(6 * 3600)
        )

        #expect(bucket.isEmpty)
    }
}

/// Reaching back is a statement about the writer being behind, and there is no
/// writer to be behind when the setting is off. The recorder throws its open
/// bucket away the moment that happens — carrying the previous minute's list
/// forward past the switch would put back exactly what the switch was for.
@Test func nothingIsCarriedForwardWhileRecordingIsOff() async throws {
    try await withStore { store in
        try store.write(
            processes: [
                ProcessRow(name: "Xcode", timestamp: bucketStart, cpuPermille: 400, footprintMB: 1, diskKBps: 0, count: 1)
            ],
            tier: .thirtySeconds
        )
        let moment = bucketStart.addingTimeInterval(35)

        let recording = try await store.consumers(
            at: moment, tier: .thirtySeconds, now: moment, isRecording: true
        )
        let stopped = try await store.consumers(
            at: moment, tier: .thirtySeconds, now: moment, isRecording: false
        )

        #expect(recording.consumers.count == 1)
        #expect(stopped.isEmpty)
    }
}

// MARK: - One name across a span (the card's strip)

@Test func aNameSeriesKeepsItsGaps() async throws {
    try await withStore { store in
        // Buckets one and four only: the strip must hand the hole back, not
        // bridge it — a missing bucket means "not in the top ten", not idle.
        try store.write(
            processes: [
                ProcessRow(name: "Xcode", timestamp: bucketStart, cpuPermille: 800, footprintMB: 100, diskKBps: 5, count: 1),
                ProcessRow(name: "Xcode", timestamp: bucketStart.addingTimeInterval(90), cpuPermille: 400, footprintMB: 120, diskKBps: 0, count: 1),
                ProcessRow(name: "Safari", timestamp: bucketStart.addingTimeInterval(30), cpuPermille: 900, footprintMB: 50, diskKBps: 0, count: 1),
            ],
            tier: .thirtySeconds
        )

        let reader = HistoryReader(store: store)
        let now = bucketStart.addingTimeInterval(120)
        let history = try await reader.processHistory(name: "Xcode", span: 3600, now: now)

        #expect(history.tier == .thirtySeconds)
        #expect(history.points.count == 2)
        #expect(history.points.map(\.bucketStart) == [bucketStart, bucketStart.addingTimeInterval(90)])
        #expect(history.points.first?.cpu == 0.8)
        #expect(history.points.first?.footprint == 100 * megabyte)
        #expect(history.points.first?.diskRate == 5120.0)
    }
}

@Test func anUnknownNameIsAnEmptyHistoryNotAnError() async throws {
    try await withStore { store in
        let reader = HistoryReader(store: store)
        let history = try await reader.processHistory(name: "never-ran", span: 3600)
        #expect(history.points.isEmpty)
    }
}

@Test func theStripsTierFollowsItsSpan() async throws {
    try await withStore { store in
        try store.write(
            processes: [
                ProcessRow(name: "Xcode", timestamp: bucketStart, cpuPermille: 500, footprintMB: 10, diskKBps: 0, count: 1)
            ],
            tier: .minute
        )
        let reader = HistoryReader(store: store)
        let now = bucketStart.addingTimeInterval(600)

        let hour = try await reader.processHistory(name: "Xcode", span: 3600, now: now)
        #expect(hour.tier == .thirtySeconds)

        let day = try await reader.processHistory(name: "Xcode", span: 24 * 3600, now: now)
        #expect(day.tier == .minute)
        #expect(day.points.count == 1)
    }
}
