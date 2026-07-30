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
        try addAgentColumn()
    }

    /// Records which agent produced a row, instead of guessing it from the model name.
    ///
    /// The guess worked while there were two: nothing but Codex wrote `gpt-*` into this
    /// table. opencode runs whatever model it is pointed at — Claude and GPT included — so
    /// the name stopped identifying anything, and a third tab could not have been built on
    /// it. The rows already indexed are backfilled with the very rule the column replaces,
    /// which is why the numbers on screen do not move when this runs.
    ///
    /// The backfill runs on every open, not only on the one that adds the column. During an
    /// upgrade the previous version is still running, and its inserts — which know nothing
    /// of this column — land on the empty default: rows belonging to no agent, and therefore
    /// showing under no tab. Three of them appeared within a minute of the first migration
    /// on this machine. Naming them on the next open costs one indexless scan and is the
    /// difference between a tab that is right and a tab that is quietly short.
    private func addAgentColumn() throws {
        var columns: [String] = []
        try database.query("PRAGMA table_info(usage_event)") { row in
            if let name = row.string(1) { columns.append(name) }
        }
        if !columns.contains("agent") {
            try database.execute(
                "ALTER TABLE usage_event ADD COLUMN agent TEXT NOT NULL DEFAULT ''")
        }

        try database.execute(
            """
            UPDATE usage_event
               SET agent = CASE WHEN model LIKE 'gpt%' THEN 'codex' ELSE 'claude' END
             WHERE agent = ''
            """)
    }

    // MARK: - Writing

    /// Puts a price on rows that were indexed before the list knew their model.
    ///
    /// A row's cost is stored when it is inserted, and stays: what a response cost is what
    /// it cost, not what the same tokens would cost today. But a model the table had never
    /// heard of was stored at *zero*, and zero is not a price — it is the absence of one,
    /// reading on screen as "this was free". Codex arrived this way: two years of rollouts
    /// indexed against a price list that only carried Anthropic.
    ///
    /// So this corrects only the zeroes, only for models that now have a price, and leaves
    /// every priced row exactly as it was found.
    ///
    /// opencode's rows are left alone whatever they say. It publishes the price with the
    /// message, so a zero there *is* a price — a free model, or a plan that did not bill
    /// this call — and overwriting it with what the tokens would have cost through an API
    /// nobody called would be inventing a number, not repairing one.
    ///
    /// The lookup is a parameter so a test can hand it a table without mutating the
    /// process-wide one and leaking a price into every case that runs after it.
    @discardableResult
    public func repriceUnpriced(
        using price: (String) -> ModelPricing? = { Pricing.pricing(for: $0) }
    ) throws -> Int {
        let unpriced = "cost = 0 AND agent <> '\(Agent.opencode.rawValue)'"
        var models: [String] = []
        try database.query(
            "SELECT DISTINCT model FROM usage_event WHERE \(unpriced)"
        ) { row in
            if let model = row.string(0) { models.append(model) }
        }

        var repriced = 0
        for model in models {
            guard let price = price(model) else { continue }
            let million = 1_000_000.0
            try database.execute(
                """
                UPDATE usage_event SET cost =
                    (input * \(price.inputPerMillion)
                     + output * \(price.outputPerMillion)
                     + cache_read * \(price.cacheReadPerMillion)
                     + cache_write_5m * \(price.cacheWrite5mPerMillion)
                     + cache_write_1h * \(price.cacheWrite1hPerMillion)) / \(million)
                WHERE model = '\(model.replacingOccurrences(of: "'", with: "''"))'
                  AND \(unpriced)
                """)
            repriced += 1
        }
        return repriced
    }

    /// Inserts events, ignoring ones already indexed. Returns how many were new.
    @discardableResult
    public func insert(_ events: [UsageEvent]) throws -> Int {
        guard !events.isEmpty else { return 0 }

        return try database.transaction {
            let statement = try database.prepare(
                """
                INSERT OR IGNORE INTO usage_event
                    (msg_id, request_id, ts, model, input, output,
                     cache_read, cache_write_5m, cache_write_1h, cost, session_id, cwd,
                     agent)
                VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13)
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
                // What the agent says it was billed, when it says so. opencode prices each
                // message itself, against a list that covers every provider it can reach;
                // deriving that from Perch's own table would report the models it does not
                // carry at zero, which reads as free rather than as unpriced.
                statement.bind(10, event.cost ?? Pricing.cost(of: event))
                statement.bind(11, event.sessionId)
                statement.bind(12, event.cwd)
                statement.bind(13, event.agent.rawValue)
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

    /// Which agent's rows a query is about.
    ///
    /// Told apart by a column, written by whichever reader produced the row. It used to be
    /// told apart by the model name — `gpt-*` was Codex and everything else was Claude —
    /// which held for exactly as long as each agent had its own vendor. opencode picks its
    /// model from a list that spans every provider, so it can and does write `claude-*` and
    /// `gpt-*` rows; under the old rule its tokens would have been filed under the two tabs
    /// it is not.
    public enum Agent: String, Sendable, CaseIterable {
        case claude
        case codex
        case opencode

        var predicate: String { "agent = '\(rawValue)'" }
    }

    /// `WHERE` for a time bound and an agent, either of which may be absent.
    private func clause(since: Date?, agent: Agent?) -> String {
        var terms: [String] = []
        if let since { terms.append("ts >= \(Int(since.timeIntervalSince1970))") }
        if let agent { terms.append(agent.predicate) }
        return terms.isEmpty ? "" : "WHERE " + terms.joined(separator: " AND ")
    }

    /// True once that agent has been indexed at all.
    public func hasUsage(for agent: Agent) throws -> Bool {
        var found = false
        try database.query(
            "SELECT 1 FROM usage_event WHERE \(agent.predicate) LIMIT 1"
        ) { _ in found = true }
        return found
    }

    /// Which agents this machine has actually run, in the order the tabs list them.
    ///
    /// One query rather than one per agent, and it decides whether the selector appears at
    /// all: a tab bar with a single tab is a control with one setting, and a tab for an
    /// agent that has never run here is a tab onto an empty screen.
    public func agentsWithUsage() throws -> [Agent] {
        var found: Set<String> = []
        try database.query("SELECT DISTINCT agent FROM usage_event") { row in
            if let agent = row.string(0) { found.insert(agent) }
        }
        return Agent.allCases.filter { found.contains($0.rawValue) }
    }

    public func totals(since: Date? = nil, agent: Agent? = nil) throws -> Totals {
        var totals = Totals()
        let clause = clause(since: since, agent: agent)
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
    public func buckets(
        _ granularity: Granularity, limit: Int, since: Date? = nil, agent: Agent? = nil
    ) throws -> [Bucket] {
        var buckets: [Bucket] = []
        let clause = clause(since: since, agent: agent)
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

    public func totalsByModel(since: Date? = nil, agent: Agent? = nil) throws -> [(
        model: String, tokens: Int, cost: Double
    )] {
        var rows: [(String, Int, Double)] = []
        let clause = clause(since: since, agent: agent)
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
