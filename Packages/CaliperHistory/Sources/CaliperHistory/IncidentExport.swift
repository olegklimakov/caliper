import Foundation

/// A moment worth keeping, written out as files.
///
/// The two halves are read over different ranges on purpose. A series is one
/// number a bucket and the whole span on screen fits comfortably; the processes
/// are twenty-odd names a bucket, so the same span at a year would be millions
/// of rows answering a question about one moment. The picture carries the wide
/// context; the process rows carry the narrow one, and `notes` is what tells the
/// reader they are not the same range.
public enum IncidentExport {
    /// How far either side of the cursor the process rows reach.
    ///
    /// Bounded by construction rather than by a cap that has to be explained
    /// afterwards: at the fine tier this is twenty buckets, so a few hundred
    /// rows whatever the machine was doing.
    public static let processWindow: TimeInterval = 300

    /// The range the process rows are read over: the cursor's moment either
    /// side, stopping one flush short of now.
    ///
    /// The same rule the alert evaluator follows, for the same reason. The
    /// process recorder batches a minute at a time, so the newest minute of
    /// buckets is missing by construction — carrying the window past it would
    /// write a file whose rows stop dead in the middle of the range it claims,
    /// which reads as "nothing was running". It stops where the data stops
    /// instead, and `notes` prints the range it actually covers.
    public static func window(
        around moment: Date,
        width: TimeInterval = processWindow,
        now: Date = Date()
    ) -> (start: Date, end: Date) {
        let start = moment.addingTimeInterval(-width)
        let written = now.addingTimeInterval(-ProcessTier.flushInterval)
        return (start, max(start, min(moment.addingTimeInterval(width), written)))
    }

    /// Every stored bucket of every series in the slice.
    ///
    /// Straight out of the slice the pane is already drawing rather than a
    /// second query, which is what makes the numbers and the exported picture
    /// incapable of disagreeing. A bucket with no row is absent rather than
    /// zero — the rule the chart's gaps already follow.
    public static func series(_ slice: HistorySlice) -> String {
        var csv = "series,bucket_start,bucket_end,minimum,average,maximum,count\n"
        let width = TimeInterval(slice.tier.seconds)
        let clock = timestamps
        // In the enum's order rather than the dictionary's, so two exports of
        // the same slice are the same file.
        for series in MetricSeries.allCases {
            for sample in slice[series] {
                let aggregate = sample.aggregate
                csv += series.rawValue
                csv += "," + clock.format(sample.timestamp)
                csv += "," + clock.format(sample.timestamp.addingTimeInterval(width))
                csv += "," + number(aggregate.minimum)
                csv += "," + number(aggregate.average)
                csv += "," + number(aggregate.maximum)
                csv += ",\(aggregate.count)\n"
            }
        }
        return csv
    }

    /// What was running over each bucket of the window, one row a process.
    ///
    /// The column names carry the units, and the values are SI and unscaled, the
    /// same accounting `ProcessUsage` uses. The caveats that do not fit in a
    /// column heading — the range, and that a name missing from a bucket means
    /// "did not rank" rather than "idle" — are in `notes`.
    public static func processes(_ buckets: [ProcessBucket]) -> String {
        var csv =
            "bucket_start,bucket_end,tier,name,cpu_cores,footprint_bytes,disk_bytes_per_second,energy_joules\n"
        let clock = timestamps
        for bucket in buckets {
            let start = clock.format(bucket.start)
            let end = clock.format(bucket.end)
            for usage in bucket.consumers {
                csv += start + "," + end
                csv += "," + bucket.tier.label
                csv += "," + field(usage.name)
                csv += "," + number(usage.cpu)
                csv += ",\(usage.footprint)"
                csv += "," + number(usage.diskRate)
                csv += "," + number(usage.energy) + "\n"
            }
        }
        return csv
    }

    /// What no column heading can hold, in the folder beside the files it is
    /// about.
    ///
    /// Three facts a reader cannot recover from the files themselves, and the
    /// project's own rule about honest gaps makes each one load-bearing. The two
    /// CSVs cover *different ranges* — up to a year against ten minutes — and
    /// nothing in either says so. A process missing from a bucket means "did not
    /// rank", not "idle", which is the caveat the pane's footer prints on
    /// screen. And an empty `processes.csv` has two quite different causes:
    /// nothing was recorded around that moment, or the moment is older than the
    /// process history is kept for.
    public static func notes(
        cursor: Date,
        span: HistorySpan,
        slice: HistorySlice,
        window: (start: Date, end: Date),
        buckets: [ProcessBucket]?,
        retention: ProcessRetention
    ) -> String {
        let clock = timestamps
        var text = "Caliper incident export\n\n"
        text += "The moment: \(clock.format(cursor))\n\n"

        text += "series.csv\n"
        text += "  Every metric Caliper charts, over the \(span.title), in "
        text += "\(slice.tier.label) buckets.\n"
        text += "  A bucket with nothing recorded has no row — the Mac was asleep or "
        text += "switched\n  off. Gaps are never filled.\n\n"

        text += "processes.csv\n"
        switch buckets {
        case nil:
            text += "  Empty. The process history is kept for \(retention.label), and this "
            text += "moment is\n  older than that.\n"
        case .some(let buckets) where buckets.isEmpty:
            text += "  Empty. Nothing was recorded between \(clock.format(window.start)) and\n  "
            text += "\(clock.format(window.end)) — the Mac was asleep, or the process history "
            text += "was\n  switched off.\n"
        case .some(let buckets):
            text += "  What was running between \(clock.format(window.start)) and\n  "
            text += "\(clock.format(window.end)), in \(buckets[0].tier.label) buckets — five "
            text += "minutes either side of the\n  moment, less whatever the recorder has not "
            text += "flushed yet.\n"
            text += "  Caliper keeps only the ten heaviest processes a bucket by CPU, by memory\n"
            text += "  and by energy, so a name missing from a bucket means \"did not rank\", not\n"
            text += "  \"idle\". A pinned process is recorded every bucket whatever its rank.\n"
        }

        text += "\noverview.png\n"
        text += "  The overview pane as Caliper drew it, without its controls.\n\n"
        text += "Values are SI and unscaled, and the units are in the column headings.\n"
        text += "Timestamps are ISO-8601 with this machine's offset.\n"
        return text
    }

    /// The folder a save panel is opened with: the moment, as a name a
    /// filesystem takes. Colons are the path separator the Finder shows as a
    /// slash, so the time is written with hyphens.
    public static func folderName(for moment: Date) -> String {
        let name = Date.VerbatimFormatStyle(
            format: """
                \(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \
                \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))-\(minute: .twoDigits)
                """,
            timeZone: .current,
            calendar: .current
        )
        return "Caliper incident " + name.format(moment)
    }

    /// RFC 4180: a field holding a comma, a quote or a newline is quoted, and a
    /// quote inside one is doubled. Only the process name goes through this —
    /// every other column is a number or one of this file's own constants. A
    /// name is the one arbitrary thing here: a `.app` bundle can be called
    /// anything a person can type.
    private static func field(_ value: String) -> String {
        guard value.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" })
        else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// A decimal point, whatever the machine's locale says. The app runs in
    /// whichever one the user has, and a CSV whose numbers use a comma is one a
    /// spreadsheet imports as text.
    ///
    /// Fixed rather than `%g`, then trimmed: a disk rate of half a gigabyte a
    /// second is `5e+08` under `%g`, which a spreadsheet reads but a person
    /// skimming a bug report does not. Six decimals is far below the resolution
    /// of anything here — the store rounds to permille, megabytes and
    /// millijoules before this ever sees a value.
    private static func number(_ value: Double) -> String {
        let text = String(format: "%.6f", locale: posix, value)
        guard text.contains(".") else { return text }
        var trimmed = Substring(text)
        while trimmed.hasSuffix("0") { trimmed = trimmed.dropLast() }
        if trimmed.hasSuffix(".") { trimmed = trimmed.dropLast() }
        return String(trimmed)
    }

    /// ISO-8601 with the local offset, not UTC: a person reading a row wants
    /// the clock they remember the incident by, and the offset is what lets a
    /// machine put it back.
    ///
    /// Built per export rather than held as a constant, so it reads the zone the
    /// machine is in now — and because a `DateFormatter` shared across a package
    /// is the mutable global state strict concurrency exists to refuse.
    private static var timestamps: Date.ISO8601FormatStyle {
        Date.ISO8601FormatStyle(
            dateSeparator: .dash,
            dateTimeSeparator: .standard,
            timeSeparator: .colon,
            timeZoneSeparator: .colon,
            includingFractionalSeconds: false,
            timeZone: .current
        )
    }

    private static let posix = Locale(identifier: "en_US_POSIX")
}
