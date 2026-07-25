import Foundation

/// Turns a tool call into a reusable Claude Code permission rule.
///
/// Rules land in the project's own `.claude/settings.local.json` — the file Claude Code
/// reserves for personal, un-versioned settings. Perch never touches the user's global
/// settings on their behalf. Persistence goes through Claude Code's own
/// `updatedPermissions` contract rather than Perch editing that file behind its back;
/// `persist` remains for the paths where no decision is being returned.
public enum PermissionRule {
    /// The rule a "don't ask again" click would add, or nil when we cannot express one
    /// safely.
    public static func remembered(for request: PerchRequest) -> RememberedRule? {
        guard let tool = request.payload.toolName else { return nil }

        switch tool {
        case "Bash":
            guard let command = request.payload.toolInput?["command"]?.stringValue else {
                return nil
            }
            guard let prefix = commandPrefix(command) else { return nil }
            return RememberedRule(toolName: "Bash", content: "\(prefix):*")
        default:
            // Broad but predictable: this tool, anywhere in this project.
            return RememberedRule(toolName: tool, content: nil)
        }
    }

    /// The same rule in settings-file spelling. The UI shows this verbatim so nobody
    /// grants more than they meant to.
    public static func rule(for request: PerchRequest) -> String? {
        remembered(for: request)?.display
    }

    /// `npm run build --silent` → `npm run build`.
    ///
    /// Stops at the first token that is an option, a path, or shell punctuation, so a
    /// rule never silently covers `rm` just because it followed a `&&`.
    public static func commandPrefix(_ command: String) -> String? {
        let separators = CharacterSet(charactersIn: "|&;()<>`$\n")
        let head = command.components(separatedBy: separators).first ?? command
        var tokens: [String] = []

        for token in head.split(separator: " ", omittingEmptySubsequences: true).map(String.init) {
            if token.hasPrefix("-") || token.contains("/") || token.contains("*") { break }
            tokens.append(token)
            // Two tokens is enough to be specific (`npm run`, `git status`) without
            // turning into a rule that only ever matches once.
            if tokens.count == 2 { break }
        }

        return tokens.isEmpty ? nil : tokens.joined(separator: " ")
    }

    /// Appends the rule to the project's local settings. Returns false when there is no
    /// project directory to write to.
    @discardableResult
    public static func persist(_ rule: String, inProjectAt cwd: String?) -> Bool {
        guard let cwd else { return false }

        let directory = URL(fileURLWithPath: cwd).appendingPathComponent(".claude")
        let url = directory.appendingPathComponent("settings.local.json")

        do {
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)

            var root: [String: Any] = [:]
            if let data = try? Data(contentsOf: url),
                let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            {
                root = parsed
            }

            var permissions = root["permissions"] as? [String: Any] ?? [:]
            var allow = permissions["allow"] as? [String] ?? []
            guard !allow.contains(rule) else { return true }
            allow.append(rule)
            permissions["allow"] = allow
            root["permissions"] = permissions

            let data = try JSONSerialization.data(
                withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            NSLog("perch: could not persist rule \(rule): \(error)")
            return false
        }
    }
}
