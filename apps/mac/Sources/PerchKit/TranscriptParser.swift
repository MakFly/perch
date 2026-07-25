import Foundation

/// Reads usage out of Claude Code transcript lines (`~/.claude/projects/**/*.jsonl`).
public enum TranscriptParser {
    /// Cheap pre-filter: most lines are user messages or tool results and never carry
    /// usage. Skipping them without parsing JSON is what keeps a full re-scan of a
    /// multi-gigabyte transcript directory in the low seconds.
    public static func mightContainUsage(_ line: some StringProtocol) -> Bool {
        line.contains(#""usage""#)
    }

    public static func parse(line: Data) -> UsageEvent? {
        guard let root = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
            root["type"] as? String == "assistant",
            let message = root["message"] as? [String: Any],
            let usage = message["usage"] as? [String: Any],
            let messageId = message["id"] as? String,
            let requestId = root["requestId"] as? String,
            let model = message["model"] as? String,
            let timestamp = root["timestamp"] as? String,
            let date = parseTimestamp(timestamp)
        else { return nil }

        // `usage.cache_creation` breaks the total down by TTL. When it is missing, fall
        // back to the flat total and bill it at the 5-minute rate.
        let totalWrite = usage["cache_creation_input_tokens"] as? Int ?? 0
        let breakdown = usage["cache_creation"] as? [String: Any]
        let write1h = breakdown?["ephemeral_1h_input_tokens"] as? Int ?? 0
        let write5m = breakdown?["ephemeral_5m_input_tokens"] as? Int ?? (breakdown == nil ? totalWrite : 0)

        // Read only the top-level counters. `usage.iterations` restates the same tokens
        // per internal step, so summing it would double-count every response.
        return UsageEvent(
            messageId: messageId,
            requestId: requestId,
            timestamp: date,
            model: model,
            inputTokens: usage["input_tokens"] as? Int ?? 0,
            outputTokens: usage["output_tokens"] as? Int ?? 0,
            cacheReadTokens: usage["cache_read_input_tokens"] as? Int ?? 0,
            cacheWrite5mTokens: write5m,
            cacheWrite1hTokens: write1h,
            sessionId: root["sessionId"] as? String ?? root["session_id"] as? String,
            cwd: root["cwd"] as? String
        )
    }

    /// Parses `2026-07-25T11:07:27.354Z`.
    ///
    /// Hand-rolled rather than `ISO8601DateFormatter`: the format is fixed, this runs on
    /// every usage line in a multi-gigabyte corpus, and the formatter is not `Sendable`
    /// so it cannot be shared across the indexer's concurrency domains anyway.
    public static func parseTimestamp(_ text: String) -> Date? {
        let digits = Array(text.utf8)
        guard digits.count >= 19 else { return nil }

        func number(_ range: Range<Int>) -> Int? {
            var value = 0
            for index in range {
                let digit = Int(digits[index]) - 48  // '0'
                guard (0...9).contains(digit) else { return nil }
                value = value * 10 + digit
            }
            return value
        }

        guard let year = number(0..<4), let month = number(5..<7), let day = number(8..<10),
            let hour = number(11..<13), let minute = number(14..<16), let second = number(17..<19),
            (1...12).contains(month), (1...31).contains(day)
        else { return nil }

        // Days-from-civil (Howard Hinnant's algorithm) — no calendar object, no locale.
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        let days = era * 146_097 + dayOfEra - 719_468

        var seconds = Double(days * 86_400 + hour * 3_600 + minute * 60 + second)

        // Optional fractional part: `.354`
        if digits.count > 20, digits[19] == 0x2E, let millis = number(20..<min(23, digits.count)) {
            seconds += Double(millis) / 1000
        }

        return Date(timeIntervalSince1970: seconds)
    }
}
