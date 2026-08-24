import Foundation
import GRDB
import Security

/// Opens the history store and keeps its schema current.
///
/// WAL so the app can write while another process reads the same file — the
/// widgets in the post-MVP backlog are sandboxed and will only ever see this
/// through a shared container. A busy timeout because `SQLITE_BUSY` across
/// processes must wait rather than fail, and `synchronous = NORMAL`, which is
/// the durability a telemetry log needs: losing the last seconds of samples on
/// power loss is acceptable, stalling the sampler on every commit is not.
public enum HistoryDatabase {
    /// Group identifier a signed build uses. macOS requires the team prefix.
    public static let appGroup = "GCCNH99PN6.caliper"

    public static func open(at url: URL) throws -> DatabaseQueue {
        let queue = try DatabaseQueue(path: url.path, configuration: makeConfiguration())
        try migrator.migrate(queue)
        return queue
    }

    /// Where the store lives.
    ///
    /// The group container is where it belongs — a sandboxed widget can read
    /// nothing else — but only for a build that actually holds the entitlement.
    /// `containerURL(forSecurityApplicationGroupIdentifier:)` hands back a path
    /// to any caller, entitled or not, and an unentitled process that writes
    /// there finds the directory wedged: even `readdir` blocks afterwards. So
    /// the entitlement is checked rather than the path, and everything else
    /// records to Application Support.
    public static func defaultURL() throws -> URL {
        let directory =
            groupContainer()
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first?
                .appendingPathComponent("Caliper", isDirectory: true)

        guard let directory else {
            throw CocoaError(.fileNoSuchFile)
        }
        // Not swallowed: a directory that cannot be created turns into an
        // opaque "unable to open database" a moment later.
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory.appendingPathComponent("history.sqlite")
    }

    /// The group container, if this build is signed in a way that actually
    /// grants it.
    ///
    /// Declaring the entitlement is not enough, and checking only for it is a
    /// trap: ad-hoc signing embeds the entitlements blob verbatim, so a local
    /// build claims the group it will never be given. A team identifier is what
    /// separates a signed build from an ad-hoc one, and only a signed build is
    /// allowed into the container.
    static func groupContainer() -> URL? {
        guard let task = SecTaskCreateFromSelf(nil),
            let groups = SecTaskCopyValueForEntitlement(
                task,
                "com.apple.security.application-groups" as CFString,
                nil
            ) as? [String],
            groups.contains(appGroup),
            isSignedByGroupOwner
        else { return nil }

        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }

    /// Whether this build is signed by the team that owns the group.
    private static var isSignedByGroupOwner: Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }

        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
            let staticCode
        else { return false }

        // The team identifier is only worth reading out of a signature that is
        // actually valid.
        guard SecStaticCodeCheckValidity(staticCode, [], nil) == errSecSuccess else {
            return false
        }

        var information: CFDictionary?
        guard
            SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
                == errSecSuccess,
            let details = information as? [String: Any],
            let team = details[kSecCodeInfoTeamIdentifier as String] as? String
        else { return false }

        return appGroup.hasPrefix(team + ".")
    }

    private static func makeConfiguration() -> Configuration {
        var configuration = Configuration()
        configuration.journalMode = .wal
        configuration.busyMode = .timeout(2)
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
            // Must be set before the first table exists, or changing it later
            // needs a full VACUUM — and without it `incremental_vacuum` is
            // silently a no-op, so retention would free pages inside the file
            // that never come back to the filesystem.
            try db.execute(sql: "PRAGMA auto_vacuum = INCREMENTAL")
        }
        return configuration
    }

    /// One table per tier, each keyed by series and bucket start.
    ///
    /// `WITHOUT ROWID` with that composite key stores the row in the index
    /// itself: for a table that is only ever read as "this series, this time
    /// range", a separate rowid would be pure overhead in a file meant to hold
    /// two years of samples.
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("tiered samples") { db in
            for tier in HistoryTier.allCases {
                try db.execute(
                    sql: """
                        CREATE TABLE \(tier.tableName) (
                            series TEXT NOT NULL,
                            timestamp INTEGER NOT NULL,
                            minimum DOUBLE NOT NULL,
                            average DOUBLE NOT NULL,
                            maximum DOUBLE NOT NULL,
                            PRIMARY KEY (series, timestamp)
                        ) WITHOUT ROWID
                        """
                )
            }
        }
        // A migration of its own rather than an edit to the one above: a store
        // already on disk has the first schema recorded as applied, so editing
        // it in place leaves a table that does not match what the code expects.
        migrator.registerMigration("sample counts") { db in
            for tier in HistoryTier.allCases {
                try db.execute(
                    sql: """
                        ALTER TABLE \(tier.tableName)
                        ADD COLUMN count INTEGER NOT NULL DEFAULT 1
                        """
                )
            }
        }
        // Which processes were running, keyed the same way and stored as scaled
        // integers: SQLite varint-encodes a small integer to one or two bytes
        // where a `DOUBLE` always costs eight, and none of these three needs
        // three significant digits.
        //
        // Names are interned because otherwise `com.apple.WebKit.WebContent` is
        // written out 2880 times a day.
        migrator.registerMigration("process history") { db in
            try db.execute(
                sql: """
                    CREATE TABLE process_names (
                        id INTEGER PRIMARY KEY,
                        name TEXT NOT NULL UNIQUE
                    )
                    """
            )
            for tier in ProcessTier.allCases {
                try db.execute(
                    sql: """
                        CREATE TABLE \(tier.tableName) (
                            timestamp INTEGER NOT NULL,
                            name_id INTEGER NOT NULL,
                            cpu_permille INTEGER NOT NULL,
                            footprint_mb INTEGER NOT NULL,
                            disk_kbps INTEGER NOT NULL,
                            count INTEGER NOT NULL DEFAULT 1,
                            PRIMARY KEY (timestamp, name_id)
                        ) WITHOUT ROWID
                        """
                )
            }
        }
        return migrator
    }
}
