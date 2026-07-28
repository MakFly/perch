import Foundation

/// The last exchange of a session: what was asked, and what came back.
///
/// The panel used to show a prompt and a tool name, which answers "what is it doing" and
/// never "what did it say". Reading the reply is the reason to open a notch instead of
/// switching to the terminal — and it is already on disk, in the transcript the hook hands
/// us. Nothing here talks to a model or to a network.
public struct TranscriptTurn: Sendable, Equatable {
    /// What the user asked, as written. `nil` when the prompt fell outside the window read
    /// from the end of the file — the card has the hook's own copy to fall back on.
    public var prompt: String?
    /// Every `text` block the assistant produced since, joined in order.
    ///
    /// `thinking` is left out because it is not addressed to anyone, and `tool_use` because
    /// the activity line already says which tool is running. What is left is the prose.
    public var reply: String

    public init(prompt: String? = nil, reply: String = "") {
        self.prompt = prompt
        self.reply = reply
    }

    public var isEmpty: Bool { (prompt ?? "").isEmpty && reply.isEmpty }
}

public enum Transcript {

    /// Reads the last turn out of a Claude Code transcript.
    ///
    /// Scanned from the end for the same reason the title is: these files run to megabytes
    /// and this is re-read while a session is live. The window is larger than the title's
    /// because a turn is prose plus every tool call in between, and a 256 KB tail lands
    /// mid-turn often enough to matter.
    ///
    /// A window into the middle of a file starts mid-line; that partial line is dropped
    /// rather than parsed into something wrong.
    public static func lastTurn(path: String, maximumBytes: Int = 1024 * 1024) -> TranscriptTurn? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? handle.close() }

        guard let size = try? handle.seekToEnd(), size > 0 else { return nil }
        let start = size > UInt64(maximumBytes) ? size - UInt64(maximumBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd(), !data.isEmpty else { return nil }

        var lines = data.split(separator: UInt8(0x0A), omittingEmptySubsequences: true)
        if start > 0, !lines.isEmpty { lines.removeFirst() }

        return turn(in: lines.map { Data($0) })
    }

    /// The parsing half, separated so tests can hand it lines without a file.
    public static func turn(in lines: [Data]) -> TranscriptTurn? {
        let objects = lines.compactMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }

        // The last thing the user actually typed. Tool results come back as `user` lines
        // too — they carry `tool_result` blocks and no text — and taking one of those for
        // a prompt puts a diff where the question belongs.
        var promptIndex: Int?
        for (index, object) in objects.enumerated() where isMainThread(object) {
            guard object["type"] as? String == "user",
                let text = text(in: object), !text.isEmpty
            else { continue }
            promptIndex = index
        }

        var reply = ""
        for object in objects[(promptIndex.map { $0 + 1 } ?? 0)...] where isMainThread(object) {
            guard object["type"] as? String == "assistant", let text = text(in: object),
                !text.isEmpty
            else { continue }
            // Two blocks separated by a tool call are two paragraphs, not one sentence.
            if !reply.isEmpty { reply += "\n\n" }
            reply += text
        }

        let prompt = promptIndex.flatMap { text(in: objects[$0]) }
        let turn = TranscriptTurn(prompt: prompt, reply: reply)
        return turn.isEmpty ? nil : turn
    }

    /// Subagent transcripts are interleaved into the same file under `isSidechain`, and
    /// `isMeta` marks lines Claude Code wrote to itself. Neither is the conversation.
    private static func isMainThread(_ object: [String: Any]) -> Bool {
        object["isSidechain"] as? Bool != true && object["isMeta"] as? Bool != true
    }

    /// The prose of a message, whichever shape it arrived in.
    ///
    /// `content` is a bare string on some lines and an array of typed blocks on others —
    /// both are current, and reading only the second one loses every short user message.
    private static func text(in object: [String: Any]) -> String? {
        guard let message = object["message"] as? [String: Any] else { return nil }
        if let content = message["content"] as? String {
            return clean(content)
        }
        guard let blocks = message["content"] as? [[String: Any]] else { return nil }

        let text =
            blocks
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined(separator: "\n")
        return clean(text)
    }

    /// Claude Code wraps some of what it sends in tags the user never typed — command
    /// scaffolding, reminders injected into a turn. Showing those back would be showing
    /// the plumbing.
    private static func clean(_ text: String) -> String? {
        var result = text
        for tag in injected {
            result = result.replacingOccurrences(
                of: "<\(tag)>[\\s\\S]*?</\(tag)>", with: "", options: .regularExpression)
        }
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Wrappers Claude Code puts into the conversation that no one typed: slash-command
    /// scaffolding, reminders it writes to itself, and the notifications a finished subagent
    /// posts back. A card showing one of these says the user asked for
    /// `<task-notification><task-id>aa4f…` — which was on screen before this list grew.
    ///
    /// A message that is nothing but scaffolding comes back empty, and empty means the card
    /// falls back to the prompt the hook carried.
    private static let injected = [
        "command-name", "command-message", "command-args", "local-command-stdout",
        "system-reminder", "task-notification", "user-prompt-submit-hook",
    ]
}
