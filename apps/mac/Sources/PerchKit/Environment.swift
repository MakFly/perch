import Foundation

/// What is actually installed on this Mac.
///
/// Onboarding that asks you to tick boxes about your own machine is onboarding that has
/// not looked. Perch can see which agents and terminals are here, so the first screen
/// reports rather than interrogates.
public struct DetectedTool: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable {
        case agent
        case terminal
        case editor
    }

    public var id: String { name }
    public var name: String
    public var kind: Kind
    /// Where the evidence was found — shown so a wrong guess is arguable rather than
    /// mysterious.
    public var evidence: String
    /// Whether Perch is already wired into it. Nil for things there is nothing to wire.
    public var isConfigured: Bool?

    public init(
        name: String, kind: Kind, evidence: String, isConfigured: Bool? = nil
    ) {
        self.name = name
        self.kind = kind
        self.evidence = evidence
        self.isConfigured = isConfigured
    }
}

public enum EnvironmentScan {
    /// Agents are found by their config directory rather than by a binary on `PATH`: a GUI
    /// app does not inherit the shell's `PATH`, so looking there would miss almost
    /// everything a developer has installed.
    static let agentDirectories: [(name: String, path: String, hooks: String)] = [
        ("Claude Code", ".claude", ".claude/settings.json"),
        ("Codex", ".codex", ".codex/hooks.json"),
        ("Gemini CLI", ".gemini", ".gemini/settings.json"),
        ("Cursor CLI", ".cursor", ".cursor/hooks.json"),
        ("OpenCode", ".opencode", ".opencode/settings.json"),
    ]

    static let terminalBundles: [(String, String)] = [
        ("Terminal", "/System/Applications/Utilities/Terminal.app"),
        ("iTerm", "/Applications/iTerm.app"),
        ("Ghostty", "/Applications/Ghostty.app"),
        ("Warp", "/Applications/Warp.app"),
        ("kitty", "/Applications/kitty.app"),
        ("WezTerm", "/Applications/WezTerm.app"),
        ("Alacritty", "/Applications/Alacritty.app"),
    ]

    static let editorBundles: [(String, String, String)] = [
        ("VS Code", "/Applications/Visual Studio Code.app", ".vscode/extensions"),
        ("Cursor", "/Applications/Cursor.app", ".cursor/extensions"),
        ("Windsurf", "/Applications/Windsurf.app", ".windsurf/extensions"),
    ]

    public static func run(home: String = NSHomeDirectory()) -> [DetectedTool] {
        let manager = FileManager.default
        var found: [DetectedTool] = []

        for agent in agentDirectories {
            let directory = "\(home)/\(agent.path)"
            guard manager.fileExists(atPath: directory) else { continue }

            let hooksPath = "\(home)/\(agent.hooks)"
            let text = (try? String(contentsOfFile: hooksPath, encoding: .utf8)) ?? ""
            found.append(
                DetectedTool(
                    name: agent.name, kind: .agent, evidence: "~/\(agent.path)",
                    isConfigured: text.contains("perch-hook")))
        }

        for terminal in terminalBundles where manager.fileExists(atPath: terminal.1) {
            found.append(
                DetectedTool(name: terminal.0, kind: .terminal, evidence: terminal.1))
        }

        for editor in editorBundles where manager.fileExists(atPath: editor.1) {
            // The extension is what makes a jump land on the right tab rather than the
            // right window, so "installed" here means the extension, not the editor.
            let extensions = "\(home)/\(editor.2)"
            let installed =
                ((try? manager.contentsOfDirectory(atPath: extensions)) ?? [])
                .contains { $0.hasPrefix("kweli.perch-jump") }
            found.append(
                DetectedTool(
                    name: editor.0, kind: .editor, evidence: editor.1,
                    isConfigured: installed))
        }

        return found
    }

    /// True on a machine that has never been set up. Drives whether the first screen
    /// appears at all — an app that greets you every launch is an app you learn to dismiss
    /// without reading.
    ///
    /// The recommended install is **per project**, not global, so looking only at an
    /// agent's own config file finds nothing and greets someone who set Perch up weeks
    /// ago. Any recorded site counts.
    public static func needsOnboarding(home: String = NSHomeDirectory()) -> Bool {
        let agents = run(home: home).filter { $0.kind == .agent }
        guard !agents.isEmpty else { return false }
        guard agents.allSatisfy({ $0.isConfigured == false }) else { return false }

        let registry = URL(fileURLWithPath: home)
            .appendingPathComponent(".perch/hook-sites.json")
        guard let data = try? Data(contentsOf: registry),
            let sites = try? JSONDecoder().decode([String].self, from: data)
        else { return true }

        // A site recorded but since deleted is not evidence that Perch is set up.
        return !sites.contains { path in
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
                return false
            }
            return text.contains("perch-hook")
        }
    }
}
