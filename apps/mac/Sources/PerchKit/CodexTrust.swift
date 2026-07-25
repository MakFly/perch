import Foundation

/// Whether Codex has been told it may run Perch's hooks.
///
/// Codex records trust in `~/.codex/config.toml` as one table per hook position:
///
/// ```toml
/// [hooks.state."/Users/you/.codex/hooks.json:pre_tool_use:0:0"]
/// trusted_hash = "sha256:…"
/// ```
///
/// The hash is over a canonical form Codex does not document, and **Perch does not try to
/// reproduce it**. Writing a forged entry into a security store to save the user one
/// command would be the wrong trade even if the guess were right. So this only reads:
/// it reports whether a position is covered, and the UI says what to run when it is not.
public enum CodexTrust {
    public struct Status: Sendable, Equatable {
        public var installedPositions: Int
        public var trustedPositions: Int

        public var isFullyTrusted: Bool {
            installedPositions > 0 && trustedPositions >= installedPositions
        }
        public var needsTrust: Bool { installedPositions > trustedPositions }
    }

    /// `PreToolUse` → `pre_tool_use`, which is how Codex spells it in the state key.
    public static func stateKeyEvent(_ event: String) -> String {
        var result = ""
        for (index, character) in event.enumerated() {
            if character.isUppercase && index > 0 { result.append("_") }
            result.append(Character(character.lowercased()))
        }
        return result
    }

    /// Positions Perch occupies in a Codex `hooks.json`, as `event:matcher:hook` triples.
    public static func perchPositions(inHooksFile data: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let hooks = root["hooks"] as? [String: Any]
        else { return [] }

        var positions: [String] = []
        for (event, value) in hooks {
            guard let matchers = value as? [[String: Any]] else { continue }
            for (matcherIndex, matcher) in matchers.enumerated() {
                guard let entries = matcher["hooks"] as? [[String: Any]] else { continue }
                for (hookIndex, entry) in entries.enumerated() {
                    let command = entry["command"] as? String ?? ""
                    guard command.contains("perch-hook") else { continue }
                    positions.append("\(stateKeyEvent(event)):\(matcherIndex):\(hookIndex)")
                }
            }
        }
        return positions.sorted()
    }

    /// State keys present in `config.toml`. Only the table headers are read — enough to
    /// answer the question, and no TOML parser to keep correct.
    public static func trustedPositions(inConfig text: String, hooksPath: String) -> Set<String> {
        var result: Set<String> = []
        let prefix = "[hooks.state.\"\(hooksPath):"

        for line in text.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix(prefix), trimmed.hasSuffix("\"]") else { continue }
            let start = trimmed.index(trimmed.startIndex, offsetBy: prefix.count)
            let end = trimmed.index(trimmed.endIndex, offsetBy: -2)
            result.insert(String(trimmed[start..<end]))
        }
        return result
    }

    public static func status(
        home: String = NSHomeDirectory(),
        codexHome: String? = ProcessInfo.processInfo.environment["CODEX_HOME"]
    ) -> Status? {
        let root = codexHome ?? "\(home)/.codex"
        let hooksPath = "\(root)/hooks.json"

        guard let hooksData = try? Data(contentsOf: URL(fileURLWithPath: hooksPath)) else {
            return nil
        }
        let positions = perchPositions(inHooksFile: hooksData)
        guard !positions.isEmpty else { return nil }

        let config = (try? String(contentsOfFile: "\(root)/config.toml", encoding: .utf8)) ?? ""
        let trusted = trustedPositions(inConfig: config, hooksPath: hooksPath)

        // A position occupied by a different hook before ours could leave a stale key
        // behind, so this can read as trusted when Codex will still ask. It errs towards
        // silence rather than towards nagging.
        return Status(
            installedPositions: positions.count,
            trustedPositions: positions.filter { trusted.contains($0) }.count)
    }
}
