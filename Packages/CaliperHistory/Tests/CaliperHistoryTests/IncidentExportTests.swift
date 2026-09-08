import CaliperCore
import Foundation
import Testing

@testable import CaliperHistory

/// A ten-second boundary, so a bucket start is the timestamp it is stored as.
private let moment = Date(timeIntervalSince1970: 1_700_000_040)

private func rows(_ csv: String) -> [[String]] {
    csv.split(separator: "\n", omittingEmptySubsequences: true).map {
        $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init)
    }
}

// MARK: - The series file

@Test func writesOneRowPerStoredBucketWithBothEdgesOfIt() throws {
    let slice = HistorySlice(
        tier: .tenSeconds,
        start: moment,
        end: moment.addingTimeInterval(20),
        rows: [
            .cpu: [
                HistorySample(
                    series: .cpu,
                    timestamp: moment,
                    aggregate: Aggregate(minimum: 0.1, average: 0.25, maximum: 0.5, count: 10)
                )
            ]
        ]
    )

    let table = rows(IncidentExport.series(slice))
    #expect(table.count == 2)
    #expect(table[0] == ["series", "bucket_start", "bucket_end", "minimum", "average", "maximum", "count"])
    #expect(table[1][0] == "cpu")
    #expect(table[1][3...] == ["0.1", "0.25", "0.5", "10"])

    // Both edges, the tier's width apart: the tier is not in this file, so a
    // row that gave only its start would not say what span it covers. Parsed
    // back rather than string-matched, which would pin the test to the zone
    // the machine happens to be in.
    let iso = Date.ISO8601FormatStyle(timeZone: .current)
    #expect(try iso.parse(table[1][1]) == moment)
    #expect(try iso.parse(table[1][2]) == moment.addingTimeInterval(10))
}

@Test func leavesAGapAsAGapRatherThanFillingItWithZeroes() {
    // Two buckets a minute apart in a ten-second tier: five buckets nothing
    // was recorded for, because the Mac was asleep.
    let slice = HistorySlice(
        tier: .tenSeconds,
        start: moment,
        end: moment.addingTimeInterval(60),
        rows: [
            .cpu: [
                HistorySample(series: .cpu, timestamp: moment, aggregate: Aggregate(0.2)),
                HistorySample(
                    series: .cpu,
                    timestamp: moment.addingTimeInterval(60),
                    aggregate: Aggregate(0.3)
                ),
            ]
        ]
    )

    // Two rows and a heading, never seven: a zero row would say the machine
    // was idle where the chart draws nothing at all.
    #expect(rows(IncidentExport.series(slice)).count == 3)
}

@Test func ordersTheSeriesTheSameWayOnEveryExport() {
    let slice = HistorySlice(
        tier: .minute,
        start: moment,
        end: moment.addingTimeInterval(60),
        rows: [
            .temperature: [HistorySample(series: .temperature, timestamp: moment, aggregate: Aggregate(41))],
            .cpu: [HistorySample(series: .cpu, timestamp: moment, aggregate: Aggregate(0.2))],
            .memory: [HistorySample(series: .memory, timestamp: moment, aggregate: Aggregate(0.6))],
        ]
    )

    // The dictionary's own order is not stable across runs; the enum's is.
    let names = rows(IncidentExport.series(slice)).dropFirst().map { $0[0] }
    #expect(names == ["cpu", "memory", "temperature"])
}

@Test func writesADecimalPointWhateverTheMachinesLocaleIs() {
    // The app runs in whatever locale the user has, and a CSV whose numbers
    // use a comma is a CSV a spreadsheet imports as text — and one whose
    // fields would be split by that same comma.
    let slice = HistorySlice(
        tier: .tenSeconds,
        start: moment,
        end: moment.addingTimeInterval(10),
        rows: [.cpu: [HistorySample(series: .cpu, timestamp: moment, aggregate: Aggregate(0.375))]]
    )
    #expect(rows(IncidentExport.series(slice))[1][4] == "0.375")
}

@Test func writesALargeRateInFullRatherThanInExponent() {
    let buckets = [
        ProcessBucket(
            tier: .thirtySeconds,
            start: moment,
            consumers: [
                ProcessUsage(name: "mds_stores", cpu: 1.5, footprint: 1_048_576, diskRate: 5e8, energy: 12.5)
            ]
        )
    ]
    // `%g` would write this as `5e+08`. A spreadsheet reads that; a person
    // skimming a bug report does not.
    #expect(rows(IncidentExport.processes(buckets))[1][6] == "500000000")
}

// MARK: - The process file

@Test func quotesANameHoldingACommaOrAQuote() {
    let buckets = [
        ProcessBucket(
            tier: .thirtySeconds,
            start: moment,
            consumers: [
                ProcessUsage(name: #"Foo "Bar", baz"#, cpu: 0.5, footprint: 2_097_152, diskRate: 0, energy: 1)
            ]
        )
    ]

    let line = IncidentExport.processes(buckets).split(separator: "\n")[1]
    // RFC 4180: the field is quoted whole and the inner quotes are doubled.
    #expect(line.contains(#""Foo ""Bar"", baz""#))
}

@Test func writesTheBucketsWidthAsItsOwnColumn() {
    let buckets = [
        ProcessBucket(
            tier: .minute,
            start: moment,
            consumers: [ProcessUsage(name: "Xcode", cpu: 3, footprint: 1_048_576, diskRate: 0, energy: 0)]
        )
    ]
    let table = rows(IncidentExport.processes(buckets))
    #expect(table[0].first == "bucket_start")
    #expect(table[1][2] == "1 min")
    #expect(table[1][3] == "Xcode")
    // Bytes, not the megabytes the store keeps: the column says which.
    #expect(table[1][5] == "1048576")
}

@Test func writesAHeadingAndNothingElseForAWindowWithNoRows() {
    // What a moment older than the process retention produces. A file that
    // does not exist reads as an export that failed; one with a heading and no
    // rows reads as what it is.
    #expect(rows(IncidentExport.processes([])).count == 1)
}

// MARK: - The window

@Test func reachesFiveMinutesEitherSideOfTheCursor() {
    let window = IncidentExport.window(around: moment, now: moment.addingTimeInterval(3600))
    #expect(window.start == moment.addingTimeInterval(-300))
    #expect(window.end == moment.addingTimeInterval(300))
}

@Test func stopsOneFlushShortOfNow() {
    // The cursor on the newest bucket, which is where it sits at rest. The
    // recorder batches a minute at a time, so the last minute holds no rows and
    // a window reaching into it would look like a minute of nothing running.
    let window = IncidentExport.window(around: moment, now: moment)
    #expect(window.end == moment.addingTimeInterval(-ProcessTier.flushInterval))
    #expect(window.start <= window.end)
}

@Test func neverEndsBeforeItStarts() {
    // A machine that has only just started recording: one flush back is before
    // the window's own start.
    let window = IncidentExport.window(around: moment, now: moment.addingTimeInterval(-600))
    #expect(window.start <= window.end)
}

// MARK: - The store query

@Test func readsEveryBucketOfAWindowAndKeepsThemApart() async throws {
    try await withStore { store in
        let recorder = ProcessHistoryRecorder(store: store, isEnabled: true)
        // Three consecutive thirty-second buckets, with a name that only runs
        // in the middle one.
        for (index, extra) in [nil, "mds_stores", nil].enumerated() {
            var samples = [
                ProcessSample(
                    pid: 1,
                    name: "kernel_task",
                    cpu: Double(index) + 1,
                    memoryFootprint: 1_048_576,
                    diskRate: 0,
                    power: 0,
                    wakeupsPerSecond: 0,
                    performanceCycleShare: nil,
                    qos: nil
                )
            ]
            if let extra {
                samples.append(
                    ProcessSample(
                        pid: 2,
                        name: extra,
                        cpu: 9,
                        memoryFootprint: 2_097_152,
                        diskRate: 0,
                        power: 0,
                        wakeupsPerSecond: 0,
                        performanceCycleShare: nil,
                        qos: nil
                    )
                )
            }
            recorder.record(
                ProcessesSample(
                    sampledAt: moment.addingTimeInterval(Double(index) * 30),
                    interval: 1,
                    topByCPU: samples,
                    topByMemory: samples,
                    topByDisk: [],
                    topByPower: [],
                    watched: [],
                    roster: [],
                    births: [:],
                    unreadableCount: 0
                )
            )
        }
        try recorder.flushNow()

        func read(to end: Date) throws -> [ProcessBucket] {
            try store.databaseQueue.read { db in
                try HistoryStore.fetchConsumers(from: moment, to: end, tier: .thirtySeconds, in: db)
            }
        }
        let buckets = try read(to: moment.addingTimeInterval(90))

        // The end is exclusive: a bucket starting exactly there covers the
        // thirty seconds *after* the window, so ±5 minutes is twenty buckets
        // rather than twenty-one.
        #expect(try read(to: moment.addingTimeInterval(60)).count == 2)

        #expect(buckets.count == 3)
        #expect(buckets.map(\.start) == (0..<3).map { moment.addingTimeInterval(Double($0) * 30) })
        // A grouping that folded the window into one bucket would show two
        // names in all three.
        #expect(buckets.map(\.consumers.count) == [1, 2, 1])
        // Heaviest first inside a bucket, the order the readout uses.
        #expect(buckets[1].consumers.first?.name == "mds_stores")
    }
}

@Test func tellsNotKeptApartFromRecordedNothing() async throws {
    try await withStore { store in
        let reader = HistoryReader(store: store)

        // Older than any tier keeps: nil, not an empty list.
        let old = IncidentExport.window(around: Date().addingTimeInterval(-30 * 24 * 3600))
        #expect(try await reader.consumers(from: old.start, to: old.end, retention: .week) == nil)

        // Kept, and holding nothing — a different answer, and the note beside
        // the file is the only place it can be told.
        let recent = IncidentExport.window(around: Date().addingTimeInterval(-1800))
        let empty = try await reader.consumers(from: recent.start, to: recent.end, retention: .week)
        #expect(empty?.isEmpty == true)
    }
}

// MARK: - The note beside the files

@Test func theNoteSaysTheTwoFilesCoverDifferentRanges() {
    let slice = HistorySlice(
        tier: .tenMinutes,
        start: moment,
        end: moment.addingTimeInterval(600),
        rows: [.cpu: [HistorySample(series: .cpu, timestamp: moment, aggregate: Aggregate(0.2))]]
    )
    let window = IncidentExport.window(around: moment, now: moment.addingTimeInterval(3600))
    let note = IncidentExport.notes(
        cursor: moment,
        span: .day,
        slice: slice,
        window: window,
        buckets: [
            ProcessBucket(
                tier: .thirtySeconds,
                start: moment,
                consumers: [ProcessUsage(name: "Xcode", cpu: 1, footprint: 0, diskRate: 0, energy: 0)]
            )
        ],
        retention: .week
    )
    // A reader opening ten minutes of processes beside a day of series has no
    // way to learn they are different ranges except from this.
    #expect(note.contains("last 24 hours"))
    #expect(note.contains("five minutes either side"))
    #expect(note.contains("did not rank"))
}

@Test func theNoteSaysWhyAnEmptyProcessFileIsEmpty() {
    let slice = HistorySlice(tier: .hour, start: moment, end: moment, rows: [:])
    let window = IncidentExport.window(around: moment, now: moment.addingTimeInterval(3600))
    func note(_ buckets: [ProcessBucket]?) -> String {
        IncidentExport.notes(
            cursor: moment,
            span: .month,
            slice: slice,
            window: window,
            buckets: buckets,
            retention: .week
        )
    }
    // Not kept any more, against kept and holding nothing. The same file on
    // disk either way, so the note is the only thing that can tell them apart.
    #expect(note(nil).contains("kept for 7 days"))
    #expect(note([]).contains("Nothing was recorded"))
}
