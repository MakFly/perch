import Foundation

/// The name a session already has.
///
/// Claude Code names its own sessions — it writes an `ai-title` line into the transcript,
/// which is the title you see in `claude --resume`. So Perch reads that instead of
/// spending a model call inventing a second, different name for the same thing.
///
/// The line repeats as the title is refined, so the last one wins.
public enum SessionTitle {
    /// Scans a transcript backwards for the most recent title.
    ///
    /// Reads from the end because the newest title is the last line of its kind, and these
    /// files run to megabytes — walking one forwards on every panel redraw is not free.
    public static func read(transcriptPath: String, maximumBytes: Int = 256 * 1024) -> String? {
        guard let handle = FileHandle(forReadingAtPath: transcriptPath) else { return nil }
        defer { try? handle.close() }

        guard let size = try? handle.seekToEnd(), size > 0 else { return nil }
        let start = size > UInt64(maximumBytes) ? size - UInt64(maximumBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }

        // A window into the middle of a file starts mid-line; that partial line is dropped
        // rather than parsed into something wrong.
        var lines = data.split(separator: UInt8(0x0A), omittingEmptySubsequences: true)
        if start > 0, !lines.isEmpty { lines.removeFirst() }

        for line in lines.reversed() {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                object["type"] as? String == "ai-title",
                let title = object["aiTitle"] as? String,
                !title.isEmpty
            else { continue }
            return clean(title)
        }
        return nil
    }

    /// Titles arrive both as prose and as slugs — `Fix dark mode border styling` and
    /// `limit-active-sessions-10` are both real. The card reads better with one shape.
    static func clean(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains(" "), trimmed.contains("-") else { return trimmed }

        let words = trimmed.split(separator: "-").map(String.init)
        guard words.count > 1 else { return trimmed }
        return words.enumerated()
            .map { index, word in
                index == 0 ? word.prefix(1).uppercased() + word.dropFirst() : word
            }
            .joined(separator: " ")
    }
}
