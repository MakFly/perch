import Foundation

/// Persistent index of token usage, keyed so that re-reading a transcript is harmless.
///
/// **Sendable, deliberately unchecked.** Aggregates are read off the main actor — four
/// SQLite queries over tens of thousands of rows made the notch miss hover events when
/// they ran on it — so the store is handed to a detached task on every reload. That was
/// already true before this conformance existed; the conformance only stops it being an
/// accident.
///
/// It is sound because the connection is opened with `sqlite3_open`, and the SQLite that
/// ships with macOS is built `SQLITE_THREADSAFE=1` (serialized): the library takes its own
/// mutex per call, so one connection used from several threads is a supported
/// configuration rather than a race that has not happened yet. Anything here that stops
/// being a single connection has to revisit this.
public final class UsageStore: @unchecked Sendable {
    public enum Granularity: String, Sendable, CaseIterable {
        case minute, hour, day, month

        /// SQLite strftime format for the bucket label. Times are stored as epoch
        /// seconds and grouped in local time, because "today" means the user's today.
        var format: String {
            switch self {
            case .minute: return "%Y-%m-%d %H:%M"
            case .hour: return "%Y-%m-%d %H:00"
            case .day: return "%Y-%m-%d"
            case .month: return "%Y-%m"
            }
        }
    }

    public struct Bucket: Sendable, Identifiable {
        public var label: String
        public var tokens: Int
        public var cost: Double
        public var id: String { label }
    }

    public struct Totals: Sendable {
        public var events: Int = 0
        public var inputTokens: Int = 0
        public var outputTokens: Int = 0
        public var cacheReadTokens: Int = 0
        public var cacheWriteTokens: Int = 0
        public var cost: Double = 0

        public init() {}

        public var totalTokens: Int {
            inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens
        }
    }

    /// Where the indexer stopped reading a transcript last time.
    struct Cursor {
        var offset: Int
        var inode: Int
    }

    private let database: SQLiteDatabase

    public init(path: String) throws {
        database = try SQLiteDatabase(path: path)
        try migrate()
    }

    public static var defaultURL: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Perch", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("usage.sqlite")
    }

    private func migrate() throws {
        // The primary key is the deduplication: transcripts repeat entries constantly
        // (56% of usage lines on a real machine), so inserts are INSERT OR IGNORE and
        // re-indexing a file can never inflate the totals.
        try database.execute(
            """
            CREATE TABLE IF NOT EXISTS usage_event (
                msg_id           TEXT NOT NULL,
                request_id       TEXT NOT NULL,
                ts               INTEGER NOT NULL,
                model            TEXT NOT NULL,
                input            INTEGER NOT NULL,
                output           INTEGER NOT NULL,
                cache_read       INTEGER NOT NULL,
                cache_write_5m   INTEGER NOT NULL,
                cache_write_1h   INTEGER NOT NULL,
                cost             REAL NOT NULL,
                session_id       TEXT,
                cwd              TEXT,
                PRIMARY KEY (msg_id, request_id)
            );
            CREATE INDEX IF NOT EXISTS idx_usage_ts ON usage_event (ts);

            CREATE TABLE IF NOT EXISTS file_cursor (
                path   TEXT PRIMARY KEY,
                inode  INTEGER NOT NULL,
                offset INTEGER NOT NULL
            );
            """)
    }

    // MARK: - Writing

    /// Inserts events, ignoring ones already indexed. Returns how many were new.
    @discardableResult
    public func insert(_ events: [UsageEvent]) throws -> Int {
        guard !events.isEmpty else { return 0 }

        return try database.transaction {
            let statement = try database.prepare(
                """
                INSERT OR IGNORE INTO usage_event
                    (msg_id, request_id, ts, model, input, output,
                     cache_read, cache_write_5m, cache_write_1h, cost, session_id, cwd)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
                """)
            defer { statement.finalize() }

            var inserted = 0
            for event in events {
                statement.bind(1, event.messageId)
                statement.bind(2, event.requestId)
                statement.bind(3, Int(event.timestamp.timeIntervalSince1970))
                statement.bind(4, event.model)
                statement.bind(5, event.inputTokens)
                statement.bind(6, event.outputTokens)
                statement.bind(7, event.cacheReadTokens)
                statement.bind(8, event.cacheWrite5mTokens)
                statement.bind(9, event.cacheWrite1hTokens)
                statement.bind(10, Pricing.cost(of: event))
                statement.bind(11, event.sessionId)
                statement.bind(12, event.cwd)
                try statement.step()
                inserted += changesInLastStatement()
                statement.reset()
            }
            return inserted
        }
    }

    private func changesInLastStatement() -> Int {
        var count = 0
        try? database.query("SELECT changes()") { count = $0.int(0) }
        return count
    }

    // MARK: - File cursors

    func cursor(forPath path: String) -> Cursor? {
        var cursor: Cursor?
        try? database.query(
            "SELECT offset, inode FROM file_cursor WHERE path = ?1",
            bind: { $0.bind(1, path) },
            row: { cursor = Cursor(offset: $0.int(0), inode: $0.int(1)) }
        )
        return cursor
    }

    func setCursor(_ cursor: Cursor, forPath path: String) throws {
        let statement = try database.prepare(
            """
            INSERT INTO file_cursor (path, inode, offset) VALUES (?1, ?2, ?3)
            ON CONFLICT(path) DO UPDATE SET inode = ?2, offset = ?3
            """)
        defer { statement.finalize() }
        statement.bind(1, path)
        statement.bind(2, cursor.inode)
        statement.bind(3, cursor.offset)
        try statement.step()
    }

    // MARK: - Reading

    public func totals(since: Date? = nil) throws -> Totals {
        var totals = Totals()
        let clause = since.map { "WHERE ts >= \(Int($0.timeIntervalSince1970))" } ?? ""
        try database.query(
            """
            SELECT COUNT(*), COALESCE(SUM(input), 0), COALESCE(SUM(output), 0),
                   COALESCE(SUM(cache_read), 0),
                   COALESCE(SUM(cache_write_5m) + SUM(cache_write_1h), 0),
                   COALESCE(SUM(cost), 0)
            FROM usage_event \(clause)
            """
        ) { row in
            totals.events = row.int(0)
            totals.inputTokens = row.int(1)
            totals.outputTokens = row.int(2)
            totals.cacheReadTokens = row.int(3)
            totals.cacheWriteTokens = row.int(4)
            totals.cost = row.double(5)
        }
        return totals
    }

    /// Aggregates on the fly rather than maintaining rollup tables: the corpus is tens
    /// of thousands of rows, the index on `ts` makes this sub-millisecond, and there is
    /// no denormalised copy that can drift out of sync with the raw events.
    public func buckets(_ granularity: Granularity, limit: Int, since: Date? = nil) throws
        -> [Bucket]
    {
        var buckets: [Bucket] = []
        let clause = since.map { "WHERE ts >= \(Int($0.timeIntervalSince1970))" } ?? ""
        try database.query(
            """
            SELECT strftime('\(granularity.format)', ts, 'unixepoch', 'localtime') AS bucket,
                   SUM(input + output + cache_read + cache_write_5m + cache_write_1h),
                   SUM(cost)
            FROM usage_event \(clause)
            GROUP BY bucket
            ORDER BY bucket DESC
            LIMIT \(limit)
            """
        ) { row in
            guard let label = row.string(0) else { return }
            buckets.append(Bucket(label: label, tokens: row.int(1), cost: row.double(2)))
        }
        return buckets.reversed()
    }

    /// One row per local day and model — the shape the leaderboard is published in.
    public struct DailyModelUsage: Sendable, Equatable {
        public var day: String
        public var model: String
        public var inputTokens: Int
        public var outputTokens: Int
        public var cacheReadTokens: Int
        public var cacheWriteTokens: Int
        public var cost: Double
    }

    /// What a day looked like, independent of which models were used in it.
    public struct DailyActivity: Sendable, Equatable {
        public var day: String
        /// Minutes in which *something* was produced, times 60.
        ///
        /// Perch has no clock on the user; it has evidence of work. A minute with a usage
        /// event in it is a minute the agent was running, and counting those is a claim
        /// that can be checked. Wall time between the first and last event of a day would
        /// count lunch.
        public var focusSeconds: Int
        public var sessions: Int
    }

    public func dailyByModel(since: Date? = nil) throws -> [DailyModelUsage] {
        var rows: [DailyModelUsage] = []
        let clause = since.map { "WHERE ts >= \(Int($0.timeIntervalSince1970))" } ?? ""
        try database.query(
            """
            SELECT strftime('%Y-%m-%d', ts, 'unixepoch', 'localtime') AS day,
                   model,
                   SUM(input), SUM(output), SUM(cache_read),
                   SUM(cache_write_5m) + SUM(cache_write_1h),
                   SUM(cost)
            FROM usage_event \(clause)
            GROUP BY day, model
            ORDER BY day ASC
            """
        ) { row in
            guard let day = row.string(0) else { return }
            rows.append(
                DailyModelUsage(
                    day: day,
                    model: row.string(1) ?? "?",
                    inputTokens: row.int(2),
                    outputTokens: row.int(3),
                    cacheReadTokens: row.int(4),
                    cacheWriteTokens: row.int(5),
                    cost: row.double(6)))
        }
        return rows
    }

    public func dailyActivity(since: Date? = nil) throws -> [DailyActivity] {
        var rows: [DailyActivity] = []
        let clause = since.map { "WHERE ts >= \(Int($0.timeIntervalSince1970))" } ?? ""
        try database.query(
            """
            SELECT strftime('%Y-%m-%d', ts, 'unixepoch', 'localtime') AS day,
                   COUNT(DISTINCT strftime('%Y-%m-%d %H:%M', ts, 'unixepoch', 'localtime')),
                   COUNT(DISTINCT session_id)
            FROM usage_event \(clause)
            GROUP BY day
            ORDER BY day ASC
            """
        ) { row in
            guard let day = row.string(0) else { return }
            rows.append(
                DailyActivity(day: day, focusSeconds: row.int(1) * 60, sessions: row.int(2)))
        }
        return rows
    }

    public func totalsByModel(since: Date? = nil) throws -> [(model: String, tokens: Int, cost: Double)] {
        var rows: [(String, Int, Double)] = []
        let clause = since.map { "WHERE ts >= \(Int($0.timeIntervalSince1970))" } ?? ""
        try database.query(
            """
            SELECT model,
                   SUM(input + output + cache_read + cache_write_5m + cache_write_1h),
                   SUM(cost)
            FROM usage_event \(clause)
            GROUP BY model
            ORDER BY 3 DESC
            """
        ) { row in
            rows.append((row.string(0) ?? "?", row.int(1), row.double(2)))
        }
        return rows
    }
}
