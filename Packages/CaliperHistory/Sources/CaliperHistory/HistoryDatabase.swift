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

    /// Where the store lives: the group container for a build that actually
    /// holds the entitlement, Application Support for everything else.
    ///
    /// `containerURL(forSecurityApplicationGroupIdentifier:)` hands a path to
    /// any caller, entitled or not, and an unentitled process that writes there
    /// wedges the directory — even `readdir` blocks afterwards. So the
    /// entitlement is checked rather than the path.
    public static func defaultURL() throws -> URL {
        let directory =
            groupContainer()
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first?
                .appendingPathComponent("Caliper", isDirectory: true)

        guard let directory else {
            throw CocoaError(.fileNoSuchFile)
        }
        // Or it turns into an opaque "unable to open database" a moment
        // later.
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        return directory.appendingPathComponent("history.sqlite")
    }

    /// The group container, if this build is signed in a way that grants it.
    ///
    /// Checking the entitlement alone is a trap: ad-hoc signing embeds the blob
    /// verbatim, so a local build claims a group it will never be given. A team
    /// identifier is what separates a signed build from an ad-hoc one.
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

        // Only worth reading out of a signature that is actually valid.
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
            // Before the first table exists, or changing it later needs a full
            // VACUUM — and without it `incremental_vacuum` is silently a no-op,
            // so retention frees pages that never reach the filesystem.
            try db.execute(sql: "PRAGMA auto_vacuum = INCREMENTAL")
        }
        return configuration
    }

    /// One table per tier, keyed by series and bucket start. `WITHOUT ROWID`
    /// stores the row in the index itself: for a table only ever read as "this
    /// series, this time range", a rowid is pure overhead.
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
        // Its own migration, not an edit to the one above: a store on disk has
        // the first schema recorded as applied.
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
        // Scaled integers: SQLite varint-encodes a small integer to one or two
        // bytes where a `DOUBLE` always costs eight. Names are interned because
        // otherwise `com.apple.WebKit.WebContent` is written 2880 times a day.
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
        // Energy rather than mean watts: it is the only one of the four that
        // adds up, so a rollup sums it and a card can total a week of it.
        // Millijoules because SQLite varints the value — an idle daemon's
        // bucket stays two bytes where joules would round it away entirely.
        migrator.registerMigration("process energy and inventory") { db in
            for tier in ProcessTier.allCases {
                try db.execute(
                    sql: """
                        ALTER TABLE \(tier.tableName)
                        ADD COLUMN energy_mj INTEGER NOT NULL DEFAULT 0
                        """
                )
                // Why the row is here. The rollup re-ranks, so without a
                // recorded reason a pinned row is evicted the moment thirty
                // seconds folds into a minute — a strip continuous for an hour
                // and a comb for a day.
                try db.execute(
                    sql: """
                        ALTER TABLE \(tier.tableName)
                        ADD COLUMN keep INTEGER NOT NULL DEFAULT 0
                        """
                )
            }
            // One row a name, and one a name a day with an hour per bit. Which
            // makes it affordable for *every* name rather than the ranked
            // twenty: ~600 names cost around 6 KB a day here, against the
            // ~180 MB a fortnight recording them all in the tiers would.
            try db.execute(
                sql: """
                    CREATE TABLE process_inventory (
                        name_id INTEGER PRIMARY KEY REFERENCES process_names(id),
                        first_seen INTEGER NOT NULL,
                        last_seen INTEGER NOT NULL,
                        path TEXT
                    ) WITHOUT ROWID
                    """
            )
            try db.execute(
                sql: """
                    CREATE TABLE process_presence (
                        name_id INTEGER NOT NULL REFERENCES process_names(id),
                        day INTEGER NOT NULL,
                        hours INTEGER NOT NULL,
                        PRIMARY KEY (name_id, day)
                    ) WITHOUT ROWID
                    """
            )
        }
        return migrator
    }
}
