import Foundation
import PerchKit

/// One thing that happened in a Claude Code session, rendered for a very small screen.
///
/// A tool produces two hooks — before and after — but the user thinks of it as one line
/// that changes state, so `PostToolUse` completes the existing row instead of adding one.
struct ActivityEvent: Identifiable, Sendable {
    enum Status: Sendable {
        case running
        case done
        case failed
    }

    let id = UUID()
    let date: Date
    let kind: String
    let sessionId: String?
    let cwd: String?
    let tool: String?
    let detail: String
    var status: Status

    init(request: PerchRequest, date: Date = .now) {
        self.date = date
        self.kind = request.event
        self.sessionId = request.payload.sessionId
        self.cwd = request.payload.cwd
        self.tool = request.payload.toolName
        self.detail = Self.summarize(request)
        self.status = request.event == "PreToolUse" ? .running : .done
    }

    /// Two hooks describe the same tool call when they share session, tool and target.
    func matches(_ other: ActivityEvent) -> Bool {
        sessionId == other.sessionId && tool == other.tool && detail == other.detail
    }

    /// The notch shows a single line, so pick the one field that says the most about
    /// what the tool is about to do.
    static func summarize(_ request: PerchRequest) -> String {
        let payload = request.payload
        if let message = payload.message, !message.isEmpty { return message }
        if let prompt = payload.prompt, !prompt.isEmpty { return prompt }

        guard let input = payload.toolInput else { return payload.toolName ?? request.event }

        switch payload.toolName {
        case "Bash":
            return input["command"]?.stringValue ?? ""
        case "Read", "Write", "Edit", "NotebookEdit":
            return input["file_path"]?.stringValue.map(abbreviate) ?? ""
        case "Glob", "Grep":
            let pattern = input["pattern"]?.stringValue ?? ""
            let path = input["path"]?.stringValue.map(abbreviate) ?? ""
            return path.isEmpty ? pattern : "\(pattern) in \(path)"
        case "WebFetch":
            return input["url"]?.stringValue ?? ""
        case "Task", "Agent":
            return input["description"]?.stringValue ?? ""
        default:
            return input.displayText
        }
    }

    /// `/Users/kevin/lab/x.swift` reads better as `~/lab/x.swift` in 190 points.
    static func abbreviate(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    var projectName: String? {
        cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
    }
}
