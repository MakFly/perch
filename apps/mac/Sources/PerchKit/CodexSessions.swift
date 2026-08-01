import Foundation

/// The Codex sessions running right now, read from the rollouts they are writing.
///
/// Codex reaches the panel through its usage — `CodexRollout` has been reading these same
/// files for tokens and quota since Codex got its own tab — but never as a *session*. The
/// cards are fed by hooks, and hooks are a CLI feature: the desktop app is an Electron
/// application that shares `~/.codex` and does not run them. So a Codex Desktop session
/// could be reasoning in the foreground with the island showing nothing at all, while the
/// Stats tab counted its tokens.
///
/// Nothing here needs a hook. A live session writes a rollout continuously, and the file
/// says everything a card wants:
///
/// ```
/// {"type":"session_meta",  "payload":{"session_id":…, "cwd":…, "originator":"Codex Desktop"}}
/// {"type":"response_item", "payload":{"type":"custom_tool_call", "name":"exec", "input":…}}
/// {"type":"response_item", "payload":{"type":"reasoning"}}
/// {"type":"event_msg",     "payload":{"type":"agent_message", "message":…}}
/// ```
///
/// The name a person would recognise is not in there — it is in `~/.codex/session_index.jsonl`,
/// one line per thread, which is what the desktop app shows in its own sidebar. Perch reads
/// that rather than inventing a second name for the same work, exactly as it reads Claude
/// Code's `ai-title` instead of asking a model for one.
public enum CodexSessions {

    /// A Codex session as a card would show it.
    public struct Live: Sendable, Equatable, Identifiable {
        public var id: String
        public var cwd: String?
        /// The thread name Codex gave it, from `session_index.jsonl`.
        public var title: String?
        /// `Codex Desktop`, `codex_cli_rs`, … — whatever wrote the rollout says so itself.
        public var originator: String?
        /// The activity line: what it is running, or the last thing it said.
        public var detail: String
        /// A tool call with no output after it yet.
        public var isRunningTool: Bool
        /// When the rollout was last written, which is the only liveness signal there is.
        public var updatedAt: Date

        public init(
            id: String, cwd: String? = nil, title: String? = nil, originator: String? = nil,
            detail: String = "", isRunningTool: Bool = false, updatedAt: Date = .now
        ) {
            self.id = id
            self.cwd = cwd
            self.title = title
            self.originator = originator
            self.detail = detail
            self.isRunningTool = isRunningTool
            self.updatedAt = updatedAt
        }

        /// Whether the model is mid-turn, as opposed to waiting for the next prompt.
        ///
        /// Codex writes no "the turn is over" line, so there is nothing to read for it. What
        /// there is, is silence: a session mid-turn writes reasoning, tool calls and token
        /// counts continuously, and one waiting on a person writes nothing at all. The
        /// threshold is generous because a single long tool call is a real gap.
        public func isWorking(now: Date = .now, within: TimeInterval) -> Bool {
            now.timeIntervalSince(updatedAt) <= within
        }
    }

    public static var defaultRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    public static var defaultIndex: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex/session_index.jsonl")
    }

    /// How far back a rollout may have been *created* and still be one to look at.
    ///
    /// Rollouts are filed under `sessions/YYYY/MM/DD/` by the day they started, and a
    /// session that has been open since Friday keeps writing into Friday's directory. So
    /// the walk cannot be "today"; nor should it be the whole tree, which is what the usage
    /// indexer walks and what cost 220ms a pass before it was made to skip. Three days of
    /// directory listings is a handful of `getattrlistbulk` calls, and a session older than
    /// that which is still alive is a session that will be picked up when it is restarted.
    static let daysScanned = 3

    /// Reads the rollouts that have been written to recently.
    ///
    /// - Parameters:
    ///   - activeWithin: how long after its last write a session is still worth a card.
    ///     The same timeout the hook-fed sessions use, so both kinds age out together.
    public static func live(
        root: URL = defaultRoot,
        index: URL = defaultIndex,
        now: Date = .now,
        activeWithin: TimeInterval
    ) -> [Live] {
        let titles = threadNames(index: index)
        var sessions: [Live] = []

        for url in recentRollouts(root: root, now: now, activeWithin: activeWithin) {
            guard let modified = modificationDate(of: url) else { continue }
            let header = meta(of: url)
            // The header's session id wins, and the filename is the fallback.
            //
            // They disagree, and the disagreement is the point. One `codex exec` run
            // produced two files a second apart — a short one and the 475 KB where the work
            // actually happened — with different uuids in their names and the *same*
            // `session_id` inside. Keyed on the filename that is two cards for one run;
            // keyed on the header it is one, which is what it is. A rollout whose header
            // cannot be read is still a session, so the filename remains the fallback.
            guard
                let id = header.sessionId
                    ?? CodexRollout.sessionId(inFilename: url.lastPathComponent)
            else { continue }

            let activity = lastActivity(in: url)
            sessions.append(
                Live(
                    id: id,
                    cwd: header.cwd,
                    title: titles[id],
                    originator: header.originator,
                    detail: activity.detail,
                    isRunningTool: activity.isRunningTool,
                    updatedAt: modified))
        }

        // Newest first, which is the order the strip draws them in — and the order that
        // makes the first entry per id the one to keep when a session wrote two files.
        return sessions
            .sorted { $0.updatedAt > $1.updatedAt }
            .reduce(into: (seen: Set<String>(), kept: [Live]())) { result, session in
                guard result.seen.insert(session.id).inserted else { return }
                result.kept.append(session)
            }
            .kept
    }

    // MARK: - Finding them

    /// Rollout files written recently, from the last few days of directories.
    static func recentRollouts(root: URL, now: Date, activeWithin: TimeInterval) -> [URL] {
        let manager = FileManager.default
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current

        var found: [URL] = []
        for dayOffset in 0..<daysScanned {
            guard let day = calendar.date(byAdding: .day, value: -dayOffset, to: now) else {
                continue
            }
            let parts = calendar.dateComponents([.year, .month, .day], from: day)
            guard let year = parts.year, let month = parts.month, let dayOfMonth = parts.day
            else { continue }
            let directory =
                root
                .appendingPathComponent(String(format: "%04d", year), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", month), isDirectory: true)
                .appendingPathComponent(String(format: "%02d", dayOfMonth), isDirectory: true)

            // Modification dates come off the directory listing in batches rather than a
            // `stat` per file, which is the difference this same codebase measured at six
            // times on the usage indexer.
            let entries =
                (try? manager.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
                    options: [.skipsHiddenFiles])) ?? []

            for entry in entries where entry.pathExtension == "jsonl" {
                guard let modified = modificationDate(of: entry),
                    now.timeIntervalSince(modified) <= activeWithin
                else { continue }
                found.append(entry)
            }
        }
        return found
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
    }

    // MARK: - Reading one

    struct Meta: Equatable {
        /// The session this rollout belongs to, which is not always the one its filename
        /// names. See `live`.
        var sessionId: String?
        var cwd: String?
        var originator: String?
    }

    /// The header, which is the first line of the file.
    ///
    /// Bounded, because that line carries the whole system prompt on a desktop session and
    /// runs to tens of kilobytes. Read from the top rather than remembered, because it
    /// cannot change: a rollout belongs to one session, one working directory and one
    /// originator for its whole life.
    static func meta(of url: URL, headBytes: Int = 128 * 1024) -> Meta {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Meta() }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: headBytes), !head.isEmpty,
            let newline = head.firstIndex(of: 0x0A)
        else { return Meta() }

        let line = Data(head[head.startIndex..<newline])
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            object["type"] as? String == "session_meta",
            let payload = object["payload"] as? [String: Any]
        else { return Meta() }

        return Meta(
            sessionId: payload["session_id"] as? String,
            cwd: payload["cwd"] as? String,
            originator: payload["originator"] as? String)
    }

    struct Activity: Equatable {
        var detail: String = ""
        var isRunningTool: Bool = false
    }

    /// What the session was last seen doing.
    ///
    /// Read backwards from the end of the file, and it stops at the first line that says
    /// something a card can show. A tool call is what it is running; anything after that
    /// tool's output is the model talking, and the last thing it said is what a card shows
    /// instead. `reasoning` and `token_count` are steps rather than statements — they mean
    /// the session is alive, which the modification date already said, so they are skipped
    /// rather than turned into an activity line reading "reasoning".
    static func lastActivity(in url: URL, tailBytes: Int = 64 * 1024) -> Activity {
        let lines = Transcript.tail(path: url.path, maximumBytes: tailBytes)
        // A tool whose output has already arrived is finished, and the card should not
        // still be showing it as running.
        var sawToolOutput = false

        for line in lines.reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                let payload = object["payload"] as? [String: Any],
                let kind = payload["type"] as? String
            else { continue }

            switch kind {
            case "custom_tool_call_output", "function_call_output":
                sawToolOutput = true
            case "custom_tool_call", "function_call":
                let name = payload["name"] as? String ?? "tool"
                let input = payload["input"] as? String ?? payload["arguments"] as? String ?? ""
                return Activity(
                    detail: toolSummary(name: name, input: input),
                    isRunningTool: !sawToolOutput)
            case "agent_message":
                if let message = payload["message"] as? String {
                    let summary = condense(message)
                    if !summary.isEmpty { return Activity(detail: summary) }
                }
            case "user_message":
                if let message = payload["message"] as? String {
                    let summary = condense(message)
                    if !summary.isEmpty { return Activity(detail: summary) }
                }
            default:
                continue
            }
        }
        return Activity()
    }

    /// What a tool call reads as on a card.
    ///
    /// Codex does not hand a tool a tidy argument list. The desktop app writes a fragment of
    /// JavaScript — `const r = await tools.exec_command({"cmd":"npm test"})` — and other
    /// calls arrive as a bare JSON object. Printed as they are, a card shows
    /// `wait: {"cell_id":"37","yield_time_ms":20000}`, which is the plumbing rather than the
    /// work.
    ///
    /// So the one field that is about the work is preferred when it is there, and when it is
    /// not, the tool's own name is a better answer than its arguments. Matched on the shape
    /// rather than on a list of tools, because the list is not ours and grows without saying.
    static func toolSummary(name: String, input: String) -> String {
        for key in ["cmd", "command", "query", "path", "file_path", "url"] {
            if let value = firstJSONString(forKey: key, in: input), !value.isEmpty {
                return "\(name): \(condense(value))"
            }
        }
        // Nothing worth reading inside: an object, or code wrapping one. The name alone.
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed.hasPrefix("{") || trimmed.contains("await tools.") {
            return name
        }
        let summary = condense(trimmed)
        return summary.isEmpty ? name : "\(name): \(summary)"
    }

    /// `"cmd":"npm test"` out of any text, without insisting the whole thing is JSON —
    /// most of these inputs are code with an object somewhere inside them.
    static func firstJSONString(forKey key: String, in text: String) -> String? {
        let pattern = "\"\(key)\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\""
        guard let match = text.range(of: pattern, options: .regularExpression) else { return nil }
        let fragment = String(text[match])
        guard let colon = fragment.firstIndex(of: ":") else { return nil }
        let quoted = fragment[fragment.index(after: colon)...]
            .trimmingCharacters(in: .whitespaces)
        guard quoted.count >= 2 else { return nil }
        let body = String(quoted.dropFirst().dropLast())
        // The value is a JSON string, so its escapes are JSON's.
        return
            body
            .replacingOccurrences(of: "\\n", with: " ")
            .replacingOccurrences(of: "\\t", with: " ")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    /// One line, short enough for a card.
    ///
    /// Codex wraps some of what it sends in blocks nobody typed — the desktop app posts an
    /// `<in-app-browser-context>` preamble on ambient turns — and showing those back would
    /// be showing the plumbing, the same reason `Transcript.clean` exists on the Claude side.
    static func condense(_ text: String, limit: Int = 120) -> String {
        var result = text.replacingOccurrences(
            of: "<[a-z-]+ [^>]*>[\\s\\S]*?</[a-z-]+>", with: "", options: .regularExpression)
        result = result.replacingOccurrences(
            of: "<[a-z-]+>[\\s\\S]*?</[a-z-]+>", with: "", options: .regularExpression)
        result = result.replacingOccurrences(of: "\n", with: " ")
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count > limit ? String(trimmed.prefix(limit)) + "…" : trimmed
    }

    // MARK: - Names

    /// `session_index.jsonl`, one `{id, thread_name, updated_at}` per line.
    ///
    /// The whole file, because it is a few kilobytes and there is no order to exploit: the
    /// newest name for a thread is its last line, so the map is built by letting later
    /// lines overwrite earlier ones.
    static func threadNames(index: URL) -> [String: String] {
        guard let data = try? Data(contentsOf: index) else { return [:] }
        var names: [String: String] = [:]
        for line in data.split(separator: UInt8(0x0A), omittingEmptySubsequences: true) {
            guard
                let object = try? JSONSerialization.jsonObject(with: Data(line))
                    as? [String: Any],
                let id = object["id"] as? String,
                let name = object["thread_name"] as? String, !name.isEmpty
            else { continue }
            names[id] = name
        }
        return names
    }
}
