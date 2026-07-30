import Foundation

/// Reads usage and plan quota out of Codex rollouts (`~/.codex/sessions/**/*.jsonl`).
///
/// Codex records a session as a stream of typed lines rather than as a conversation, and
/// the three that matter here arrive in a fixed order:
///
/// ```
/// {"type":"session_meta", "payload":{"session_id":…, "cwd":…}}
/// {"type":"turn_context", "payload":{"model":"gpt-5.6-terra", …}}
/// {"type":"event_msg",    "payload":{"type":"token_count",
///     "info":{"total_token_usage":{…}, "last_token_usage":{…}},
///     "rate_limits":{"primary":{"used_percent":94.0, …}, "plan_type":"plus"}}}
/// ```
///
/// So a line cannot be read on its own the way a Claude transcript line can: the model
/// belongs to the `turn_context` before it, and the session to the header above that. This
/// is a parser with state, fed one line at a time, which is why it is a struct rather than
/// the enum of free functions `TranscriptParser` is.
public struct CodexRollout: Sendable {
    private var sessionId: String?
    private var cwd: String?
    private var model: String?

    public init(sessionId: String? = nil, cwd: String? = nil, model: String? = nil) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.model = model
    }

    /// State for a file the indexer is resuming into, rather than reading from the top.
    ///
    /// `token_count` outnumbers `turn_context` by twenty to one — a turn is one exchange
    /// with the user and many calls to the model — so a parser that resumed empty would
    /// drop every counter until the next turn began. That is hundreds of events on a long
    /// session, lost silently.
    ///
    /// The session id is in the filename, so only the model has to be recovered, and the
    /// head of the file is where the session declares it. A session that switched model
    /// mid-way and is resumed past the switch attributes a few turns to the old name until
    /// the next `turn_context` puts it right: bounded and visible, where dropping them
    /// would be neither.
    public static func primed(for url: URL, headBytes: Int = 256 * 1024) -> CodexRollout {
        var rollout = CodexRollout(sessionId: sessionId(inFilename: url.lastPathComponent))

        guard let handle = try? FileHandle(forReadingFrom: url) else { return rollout }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: headBytes), !head.isEmpty else {
            return rollout
        }

        var lines = head.split(separator: UInt8(0x0A), omittingEmptySubsequences: true)
        // The window may end mid-line; that one is dropped rather than parsed into a guess.
        if head.count == headBytes, !lines.isEmpty { lines.removeLast() }
        for line in lines {
            let data = Data(line)
            guard let text = String(data: data, encoding: .utf8), mightMatter(text) else {
                continue
            }
            _ = rollout.read(line: data)
        }
        return rollout
    }

    /// `rollout-2026-07-30T14-04-24-019fb2e9-57da-7fe0-8e09-07b209405c17.jsonl` → the
    /// UUID at the end, which is the session id `session_meta` carries.
    static func sessionId(inFilename name: String) -> String? {
        let stem = name.hasSuffix(".jsonl") ? String(name.dropLast(6)) : name
        let parts = stem.split(separator: "-")
        guard parts.count >= 5 else { return nil }
        let uuid = parts.suffix(5).joined(separator: "-")
        // A UUID and nothing else: 8-4-4-4-12, hex.
        let shape = uuid.split(separator: "-").map(\.count)
        guard shape == [8, 4, 4, 4, 12],
            uuid.allSatisfy({ $0 == "-" || $0.isHexDigit })
        else { return nil }
        return uuid
    }

    /// Cheap pre-filter, same bargain as the Claude side: most lines of a rollout are
    /// message content and carry none of the three shapes below.
    public static func mightMatter(_ line: some StringProtocol) -> Bool {
        line.contains(#""token_count""#) || line.contains(#""turn_context""#)
            || line.contains(#""session_meta""#)
    }

    /// Feeds one line. Returns an event only for `token_count`; the other two arm what the
    /// next one will need.
    public mutating func read(line: Data) -> UsageEvent? {
        guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            let type = root["type"] as? String
        else { return nil }
        let payload = root["payload"] as? [String: Any]

        switch type {
        case "session_meta":
            sessionId = payload?["session_id"] as? String ?? payload?["id"] as? String
            cwd = payload?["cwd"] as? String
            return nil
        case "turn_context":
            // A session can change model mid-way — `/model` — so the latest wins.
            if let model = payload?["model"] as? String, !model.isEmpty { self.model = model }
            if let cwd = payload?["cwd"] as? String { self.cwd = cwd }
            return nil
        case "event_msg":
            guard payload?["type"] as? String == "token_count" else { return nil }
            return event(payload: payload, timestamp: root["timestamp"] as? String)
        default:
            return nil
        }
    }

    private func event(payload: [String: Any]?, timestamp: String?) -> UsageEvent? {
        guard let info = payload?["info"] as? [String: Any],
            // `last_token_usage` is this turn; `total_token_usage` is the session so far.
            // Reading the total would re-count every earlier turn on every line, so a
            // session of twenty turns would report a couple of hundred.
            let last = info["last_token_usage"] as? [String: Any],
            let timestamp,
            let date = TranscriptParser.parseTimestamp(timestamp),
            let sessionId, let model
        else { return nil }

        let input = last["input_tokens"] as? Int ?? 0
        // Cached input is a *subset* of input, not a sibling of it: on every turn measured,
        // `total_tokens == input_tokens + output_tokens`. Adding the two would double the
        // input and bill the cached half at the full rate.
        let cached = min(last["cached_input_tokens"] as? Int ?? 0, input)

        return UsageEvent(
            // A rollout has no request id, so the pair is the session and the instant. Both
            // survive a re-read, which is what the store's `(msg_id, request_id)` key needs
            // to recognise a line it has already counted.
            messageId: sessionId,
            requestId: timestamp,
            timestamp: date,
            model: model,
            inputTokens: input - cached,
            // Reasoning tokens are inside `output_tokens` and billed as output; adding
            // `reasoning_output_tokens` on top would count them twice.
            outputTokens: last["output_tokens"] as? Int ?? 0,
            cacheReadTokens: cached,
            // Not `cache_write_input_tokens`. `total_tokens` is `input + output` on every
            // turn measured, so whatever that field counts is already inside the input —
            // recording it beside them would count it twice, and `ModelPricing` would bill
            // it at Anthropic's 1.25x write rate, which OpenAI does not charge at all.
            cacheWrite5mTokens: 0,
            cacheWrite1hTokens: 0,
            sessionId: sessionId,
            cwd: cwd
        )
    }
}

/// The Codex plan quota, which turns out to be published locally after all.
///
/// Every `token_count` line carries the same `rate_limits` object the ChatGPT plan reports
/// — how much of the window is spent, how wide it is, and when it resets. So there is
/// nothing to ask a server for: the newest rollout on disk is the reading, exactly as the
/// statusline cache is the reading on the Claude side.
public enum CodexQuota {
    public static var defaultRoot: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".codex/sessions", isDirectory: true)
    }

    /// Parses the `rate_limits` object out of one `token_count` payload.
    ///
    /// `primary` and `secondary` are the plan's two windows; a plan with one leaves the
    /// other null. The window's width names it — 10080 minutes is the week — because Codex
    /// gives it no other label.
    public static func limits(fromTokenCount payload: [String: Any]) -> RateLimits? {
        guard let raw = payload["rate_limits"] as? [String: Any] else { return nil }

        var windows: [NamedWindow] = []
        func add(_ key: String) {
            guard let entry = raw[key] as? [String: Any],
                let used = number(entry["used_percent"])
            else { return }
            let resets = (entry["resets_at"] as? NSNumber).map {
                Date(timeIntervalSince1970: $0.doubleValue)
            }
            let minutes = number(entry["window_minutes"]).map(Int.init)
            windows.append(
                NamedWindow(
                    id: "codex_\(key)",
                    title: title(forWindowMinutes: minutes),
                    window: RateLimitWindow(utilization: used, resetsAt: resets)))
        }
        add("primary")
        add("secondary")

        guard !windows.isEmpty else { return nil }
        return RateLimits(modelScoped: windows)
    }

    /// `10080` → `7d`, `300` → `5h`, `60` → `1h`. An unnamed width falls back to the plain
    /// word rather than to a made-up number.
    static func title(forWindowMinutes minutes: Int?) -> String {
        guard let minutes, minutes > 0 else { return "quota" }
        if minutes % 1_440 == 0 { return "\(minutes / 1_440)d" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }

    /// The newest rollout under `root`, which is the session that last spoke to OpenAI and
    /// therefore holds the freshest reading.
    ///
    /// Codex files them as `sessions/YYYY/MM/DD/rollout-…`, so the newest is found by
    /// taking the highest-named directory at each level — four small listings — rather than
    /// by walking two years of sessions on every refresh. A tree that does not have that
    /// shape falls back to the walk, because a slow right answer beats a fast wrong one.
    public static func newestRollout(in root: URL = defaultRoot) -> URL? {
        var directory = root
        for _ in 0..<3 {
            guard let next = newestSubdirectory(of: directory) else {
                return newestRolloutByWalking(root)
            }
            directory = next
        }
        return newestFile(in: directory) ?? newestRolloutByWalking(root)
    }

    private static func newestSubdirectory(of directory: URL) -> URL? {
        let entries =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])) ?? []
        // Named by date, so the highest name is the latest day — no `stat` per entry.
        return
            entries
            .filter {
                (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            }
            .max { $0.lastPathComponent < $1.lastPathComponent }
    }

    private static func newestFile(in directory: URL) -> URL? {
        let entries =
            (try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles])) ?? []
        return
            entries
            .filter { $0.pathExtension == "jsonl" }
            .max {
                modified($0) < modified($1)
            }
    }

    private static func newestRolloutByWalking(_ root: URL) -> URL? {
        guard
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles])
        else { return nil }

        var newest: (url: URL, date: Date)?
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            let date = modified(url)
            if newest == nil || date > newest!.date { newest = (url, date) }
        }
        return newest?.url
    }

    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
    }

    /// The reading, or nil when Codex has never run here.
    ///
    /// The rollout is read from the end: these files reach tens of megabytes, the quota is
    /// on the last `token_count` line, and reading forward to find it would be a megabyte
    /// of parsing per refresh.
    public static func read(root: URL = defaultRoot) -> UsageLimitsReader.Reading? {
        guard let url = newestRollout(in: root) else { return nil }
        guard let limits = limits(inRollout: url) else { return nil }
        let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[
            .modificationDate]
        return UsageLimitsReader.Reading(limits: limits, updatedAt: modified as? Date)
    }

    static func limits(inRollout url: URL) -> RateLimits? {
        limits(inLines: Transcript.tail(path: url.path))
    }

    /// The parsing half, separated so tests can hand it lines without a file.
    static func limits(inLines lines: [Data]) -> RateLimits? {
        // From the end: the last reading is the current one, and everything above it in the
        // file is the same window earlier in the day.
        for line in lines.reversed() {
            guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                let payload = root["payload"] as? [String: Any],
                payload["type"] as? String == "token_count",
                let limits = limits(fromTokenCount: payload)
            else { continue }
            return limits
        }
        return nil
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
