import Foundation

/// Reads usage out of opencode's store, which is a SQLite database rather than a directory
/// of transcripts.
///
/// Claude Code and Codex both append lines to files, so Perch reads them by remembering a
/// byte offset. opencode keeps its sessions in `~/.local/share/opencode/opencode.db` —
/// `storage/` holds only migrations and diffs now — and one billed response is one row of
/// `message`, whose `data` column is the JSON that carries everything worth counting:
///
/// ```json
/// {"role":"assistant","modelID":"deepseek-v4-flash-free","providerID":"opencode",
///  "cost":0,"tokens":{"input":363,"output":29,"reasoning":0,
///                     "cache":{"read":21760,"write":0}},
///  "time":{"created":1785273371310,"completed":1785273372103},
///  "path":{"cwd":"/Users/…/saas"}}
/// ```
///
/// The model is on the message, not on the session: opencode switches model mid-session
/// and each response records the one that produced it. That is the whole detection — no
/// guessing from a provider name, and no session-level average.
public enum OpencodeUsage {
    /// Where opencode keeps its store, honouring `XDG_DATA_HOME` the way opencode does.
    public static var defaultDatabaseURL: URL {
        let root: URL
        if let xdg = ProcessInfo.processInfo.environment["XDG_DATA_HOME"], !xdg.isEmpty {
            root = URL(fileURLWithPath: xdg)
        } else {
            root = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent(".local/share", isDirectory: true)
        }
        return root.appendingPathComponent("opencode/opencode.db")
    }

    /// A pass over the store: the events read, and how far they got.
    public struct Reading: Sendable {
        public var events: [UsageEvent]
        /// The highest `time_updated` seen, in milliseconds — where the next pass resumes.
        public var watermark: Int
    }

    /// Reads every assistant message updated at or after `watermark`.
    ///
    /// **At or after**, not after: two messages can share a millisecond, and `>` would drop
    /// the second one forever. Re-reading the boundary row costs nothing, because
    /// `usage_event` is keyed on `(msg_id, request_id)` and an opencode message id is unique
    /// by construction.
    ///
    /// The database is opened read-only. It belongs to opencode, which may well be running:
    /// nothing is written, no journal mode is changed, and a missing file is simply an
    /// opencode that has never run here.
    public static func read(
        databaseURL: URL = defaultDatabaseURL, since watermark: Int = 0
    ) throws -> Reading? {
        guard FileManager.default.fileExists(atPath: databaseURL.path) else { return nil }
        let database = try SQLiteDatabase(path: databaseURL.path, readOnly: true)

        var events: [UsageEvent] = []
        var highest = watermark
        try database.query(
            """
            SELECT id, session_id, time_updated, data
            FROM message
            WHERE json_extract(data, '$.role') = 'assistant'
              AND time_updated >= ?1
            ORDER BY time_updated ASC
            """,
            bind: { $0.bind(1, watermark) },
            row: { row in
                highest = max(highest, row.int(2))
                guard let id = row.string(0), let json = row.string(3),
                    let event = event(id: id, sessionId: row.string(1), data: json)
                else { return }
                events.append(event)
            })

        return Reading(events: events, watermark: highest)
    }

    /// One row's `data` into an event, or nil for a row there is nothing to count in.
    ///
    /// Two are skipped. A message with no `time.completed` is a turn still in flight, and a
    /// message with no tokens at all is one that was aborted — inserting either would freeze
    /// it at zero, because `INSERT OR IGNORE` never revisits a row it has already stored.
    /// Skipping is safe in a way that inserting is not: the next pass sees the same message
    /// with its counters filled in.
    static func event(id: String, sessionId: String?, data json: String) -> UsageEvent? {
        guard let root = try? JSONSerialization.jsonObject(with: Data(json.utf8))
                as? [String: Any]
        else { return nil }

        let time = root["time"] as? [String: Any]
        guard number(time?["completed"]) != nil,
            let created = number(time?["created"]),
            let model = root["modelID"] as? String, !model.isEmpty
        else { return nil }

        let tokens = root["tokens"] as? [String: Any] ?? [:]
        let cache = tokens["cache"] as? [String: Any] ?? [:]
        let input = integer(tokens["input"])
        // `reasoning` is inside `output`, the same way it is in a Codex rollout. Adding it
        // beside would bill the thinking twice.
        let output = integer(tokens["output"])
        let cacheRead = integer(cache["read"])
        // opencode counts cache writes once, with no TTL to tell them apart. Filing them
        // under the 5-minute rate is the conservative reading: 1.25x input rather than 2x.
        let cacheWrite = integer(cache["write"])
        guard input + output + cacheRead + cacheWrite > 0 else { return nil }

        return UsageEvent(
            agent: .opencode,
            // The message id is unique across the store, so the pair that keys the index
            // never collides; the provider is the second half because it is what makes the
            // row legible when it is read back out.
            messageId: id,
            requestId: root["providerID"] as? String ?? "opencode",
            timestamp: Date(timeIntervalSince1970: created / 1_000),
            model: model,
            inputTokens: input,
            outputTokens: output,
            cacheReadTokens: cacheRead,
            cacheWrite5mTokens: cacheWrite,
            cacheWrite1hTokens: 0,
            sessionId: sessionId,
            cwd: (root["path"] as? [String: Any])?["cwd"] as? String,
            // opencode prices every message itself, against models.dev, which covers
            // providers Perch's table never will. A zero here is a free model saying so.
            cost: number(root["cost"]) ?? 0)
    }

    private static func integer(_ value: Any?) -> Int {
        max(0, Int(number(value) ?? 0))
    }

    private static func number(_ value: Any?) -> Double? {
        switch value {
        case let double as Double: return double
        case let int as Int: return Double(int)
        case let value as NSNumber: return value.doubleValue
        default: return nil
        }
    }
}
