import AppKit
import Foundation
import PerchKit

/// Executes a `JumpPlan`: brings the terminal forward and, where the host allows it,
/// selects the exact tab or split.
///
/// Everything here is best-effort by design. A jump that misses — the tab was closed, the
/// user never granted Automation — must leave the panel exactly as it was rather than
/// raising anything.
enum TerminalJumper {
    static func jump(to client: ClientInfo?) {
        let plan = TerminalJump.plan(for: client)
        guard plan.isPossible else { return }

        // tmux first: the pane has to be current before the terminal is asked to show
        // itself, or you land on the window and watch it switch.
        if let pane = plan.tmuxPane { selectTmuxPane(pane) }

        switch plan.target {
        case .iTerm(let bundleId, _), .appleTerminal(let bundleId, _):
            activate(bundleId)
            if let script = TerminalJump.script(for: plan.target) { run(script) }
        case .editorURI(let bundleId, _, _):
            // Bring the editor forward first: a URI opened at a background app focuses the
            // tab in a window you cannot see.
            activate(bundleId)
            if let url = TerminalJump.editorURL(for: plan.target) {
                NSWorkspace.shared.open(url)
            }
        case .remoteControl(let bundleId, let executable, let arguments):
            activate(bundleId)
            runTool(executable, arguments)
        case .activate(let bundleId):
            activate(bundleId)
        case .unavailable:
            break
        }
    }

    private static func activate(_ bundleId: String) {
        guard
            let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
        else { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    /// AppleScript runs off the main actor: an unresponsive terminal would otherwise
    /// freeze the panel for as long as the event takes to time out.
    private static func run(_ script: String) {
        Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", script]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                PerchLog.error("jump failed: \(error)")
            }
        }
    }

    /// Runs a terminal's own remote-control CLI.
    ///
    /// `/usr/bin/env` rather than an absolute path: these are installed by Homebrew, by
    /// the app bundle, or by hand, and hard-coding one of those is how it works on the
    /// machine it was written on and nowhere else. A missing tool is silent — the window
    /// has already been brought forward, which is most of the jump.
    private static func runTool(_ executable: String, _ arguments: [String]) {
        Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            // Homebrew's paths are not in a GUI app's inherited PATH.
            var environment = ProcessInfo.processInfo.environment
            let extra = "/opt/homebrew/bin:/usr/local/bin:/Applications/kitty.app/Contents/MacOS"
            environment["PATH"] = (environment["PATH"] ?? "") + ":" + extra
            process.environment = environment
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                PerchLog.error("\(executable) is not on PATH — jumped to the window only")
            }
        }
    }

    private static func selectTmuxPane(_ pane: String) {
        Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["tmux", "select-pane", "-t", pane]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try? process.run()
            process.waitUntilExit()
        }
    }
}
