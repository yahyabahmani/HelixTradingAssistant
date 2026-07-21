import Foundation
import GRDB

/// Thin wrapper around a GRDB DatabasePool, plus the canonical on-disk
/// path. Everything that touches SQLite goes through here so we have
/// one place to configure WAL mode, busy timeout, and migrations.
///
/// Open-source build: the DB only stores OHLC candles streamed by
/// `YahooScheduler` / `TwelveDataSpotStream`. The legacy snapshot
/// table + import flow were removed when the Iran-specific data
/// pipeline was dropped.
final class AppDatabase {
    /// The underlying pool — exposed so repos can run their own
    /// queries without going through a wrapper method per query.
    let pool: DatabasePool

    /// Repository for OHLC bars (Yahoo / Twelve Data-sourced
    /// candles).
    let ohlcRepo: OHLCRepo

    /// Disk path to the database file currently in use.
    let url: URL

    init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var config = Configuration()
        config.busyMode = .timeout(5)

        self.pool = try DatabasePool(path: url.path, configuration: config)

        var migrator = DatabaseMigrator()
        Schema.register(in: &migrator)
        try migrator.migrate(pool)

        self.ohlcRepo = OHLCRepo(pool: pool)
    }

    // ── Path resolution ────────────────────────────────────────────
    /// Canonical path: `~/Library/Application Support/HelixTrading/gold.db`.
    /// On first launch after the rebrand we transparently migrate the
    /// old `GoldMonitor/` directory if it exists, so existing users
    /// don't lose their OHLC history.
    static func defaultURL() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let newDir = appSupport.appendingPathComponent("HelixTrading", isDirectory: true)
        let oldDir = appSupport.appendingPathComponent("GoldMonitor", isDirectory: true)
        let fm = FileManager.default
        if fm.fileExists(atPath: oldDir.path) && !fm.fileExists(atPath: newDir.path) {
            try? fm.moveItem(at: oldDir, to: newDir)
        }
        return newDir.appendingPathComponent("gold.db")
    }
}
