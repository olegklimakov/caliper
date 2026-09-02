import Foundation

/// Byte rates, formatted for a place where width is fixed.
enum RateFormatter {
    /// Compact form for the menu bar: at most four characters plus a unit, so
    /// the module never needs to grow. "12,4 M" rather than "12,4 MB/s".
    static func menuBar(_ bytesPerSecond: Double) -> String {
        let (value, unit) = scaled(bytesPerSecond)
        // Below a kilobyte the scale has no prefix, and dropping the unit with
        // it leaves a bare number that could be anything — "B" is the unit.
        let symbol = unit.isEmpty ? "B" : unit
        if value >= 100 || unit == "K" {
            return "\(Int(value.rounded()))\u{2009}\(symbol)"
        }
        return Decimals.string("%.1f\u{2009}\(symbol)", value)
    }

    /// Full form for panels, where there is room to be explicit.
    static func panel(_ bytesPerSecond: Double) -> String {
        let (value, unit) = scaled(bytesPerSecond)
        let digits = value >= 100 || unit.isEmpty ? 0 : 1
        return Decimals.string("%.\(digits)f \(unit)B/s", value)
    }

    /// Powers of 1024, the unit a network stack actually counts in.
    private static func scaled(_ bytes: Double) -> (value: Double, unit: String) {
        switch bytes {
        case ..<1024: (bytes, "")
        case ..<(1024 * 1024): (bytes / 1024, "K")
        case ..<(1024 * 1024 * 1024): (bytes / (1024 * 1024), "M")
        default: (bytes / (1024 * 1024 * 1024), "G")
        }
    }
}

/// Numbers written the way the user's Mac writes them: `String(format:)`
/// without a locale always produces a full stop while `ByteCountFormatter`
/// follows the region setting, so a panel using both puts "17.5%" one line above
/// "625,8 MB".
enum Decimals {
    static func string(_ format: String, _ value: Double) -> String {
        String(format: format, locale: .current, value)
    }
}

/// `ByteCountFormatter` is not `Sendable`, and there is no reason to format
/// bytes anywhere but on the main actor — formatting is a UI concern.
@MainActor
enum ByteFormatter {
    /// Disk capacities and file sizes, in the decimal units the Finder uses:
    /// a 1 TB SSD is sold, formatted and reported as 1 TB.
    private static let fileStyle = make(.file)

    /// Memory, in the binary units a Mac counts it in. `.file` would write a
    /// 48 GB machine's 51_539_607_552 bytes as "51,54 GB" — a number that
    /// appears nowhere else on the system.
    private static let memoryStyle = make(.memory)

    static func capacity(_ bytes: UInt64) -> String {
        fileStyle.string(fromByteCount: Int64(bytes))
    }

    static func memory(_ bytes: UInt64) -> String {
        memoryStyle.string(fromByteCount: Int64(bytes))
    }

    private static func make(_ style: ByteCountFormatter.CountStyle) -> ByteCountFormatter {
        let formatter = ByteCountFormatter()
        formatter.countStyle = style
        formatter.allowedUnits = [.useTB, .useGB, .useMB]
        // Otherwise an idle swap file reads "Zero KB", which looks like a bug.
        formatter.allowsNonnumericFormatting = false
        return formatter
    }
}

enum PercentFormatter {
    /// Fractions arrive as 0…1 everywhere in the core; the UI is the only place
    /// that turns them into percentages.
    static func string(_ fraction: Double, decimals: Int = 0) -> String {
        Decimals.string("%.\(decimals)f%%", fraction * 100)
    }
}

enum TemperatureFormatter {
    static func string(_ celsius: Double) -> String {
        "\(Int(celsius.rounded()))°"
    }
}

/// Watts from the SoC's own accounting. Idle processes sit in the milliwatt
/// range, where "0,00 W" would erase the very number the card exists to show.
enum PowerFormatter {
    static func string(_ watts: Double) -> String {
        watts < 0.0995 && watts > 0
            ? Decimals.string("%.0f mW", watts * 1000)
            : Decimals.string("%.2f W", watts)
    }
}

/// Energy over a span, in the units a battery is talked about in. Joules below
/// a watt-hour, because "0,00 Wh" for a background daemon says nothing about
/// whether it drew a joule or three thousand.
enum EnergyFormatter {
    static func string(_ joules: Double) -> String {
        joules < 3600
            ? Decimals.string("%.0f J", joules)
            : Decimals.string("%.1f Wh", joules / 3600)
    }
}

enum DurationFormatter {
    /// "3 h 12 m", "48 m", "12 s" — the resolution a "running for" needs.
    static func brief(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        if total < 60 { return "\(total) s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes) m" }
        return "\(minutes / 60) h \(minutes % 60) m"
    }

    /// "1:12:44" — cumulative GPU seconds, the shape Activity Monitor uses.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        if total < 3600 {
            return String(format: "%d:%02d", total / 60, total % 60)
        }
        return String(format: "%d:%02d:%02d", total / 3600, (total / 60) % 60, total % 60)
    }
}

/// When a name was seen, as a list of hundreds of them can be read down.
///
/// Widths that narrow with age rather than "5 minutes ago": the registry is
/// written every ten minutes, so a relative time to the minute would claim a
/// precision the record does not have.
enum RegistryDate {
    /// Last seen, where the time of day is the answer — "it was running an
    /// hour ago" and "it was running at four this morning" are different
    /// facts.
    static func moment(_ date: Date, now: Date = Date()) -> String {
        if Calendar.current.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        if now.timeIntervalSince(date) < 6 * 24 * 3600 {
            return date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    /// First seen, where only the day is: what anyone wants from it is "this
    /// arrived on Tuesday", and a minute of precision on that is noise.
    static func day(_ date: Date, now: Date = Date()) -> String {
        if Calendar.current.isDate(date, inSameDayAs: now) {
            return "today"
        }
        if now.timeIntervalSince(date) < 6 * 24 * 3600 {
            return date.formatted(.dateTime.weekday(.abbreviated))
        }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}
