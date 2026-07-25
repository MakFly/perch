import Foundation

/// Where a click on a session card should take you.
///
/// Deciding this is pure — which terminal, which handle, whether we can be precise — so it
/// is testable without driving a single AppleEvent. Executing it is not, and lives in the
/// app.
public enum JumpTarget: Equatable, Sendable {
    /// iTerm2 addresses sessions by id, so this lands on the exact split pane.
    case iTerm(bundleId: String, session: String)
    /// Terminal.app exposes `tty` on every tab, which is the only handle it shares with
    /// the process running inside it.
    case appleTerminal(bundleId: String, tty: String)
    /// VS Code and its forks answer a URI, which is how an outside app reaches one tab
    /// among a dozen. Needs the Perch extension installed in that editor.
    case editorURI(bundleId: String, scheme: String, tty: String)
    /// kitty and WezTerm ship their own remote control. Running their CLI is both more
    /// precise and less fragile than driving them through AppleScript they do not support.
    case remoteControl(bundleId: String, executable: String, arguments: [String])
    /// Everything else: bring the app forward. Honest about being window-level — the
    /// per-app remote-control paths (kitty, wezterm) come later.
    case activate(bundleId: String)
    /// Nothing was captured — a session started before Perch, or a host we do not know.
    case unavailable
}

public struct JumpPlan: Equatable, Sendable {
    public var target: JumpTarget
    /// Run after the terminal is focused: inside tmux the visible pane is tmux's choice,
    /// not the terminal's.
    public var tmuxPane: String?

    public var isPossible: Bool { target != .unavailable }

    /// What the UI says it will do, so a click never surprises anyone.
    public var summary: String {
        switch target {
        case .iTerm: return "Jump to iTerm"
        case .appleTerminal: return "Jump to Terminal"
        case .editorURI(let bundleId, _, _), .remoteControl(let bundleId, _, _):
            return "Jump to \(TerminalJump.name(forBundle: bundleId))"
        case .activate(let bundleId): return "Open \(TerminalJump.name(forBundle: bundleId))"
        case .unavailable: return "No terminal recorded"
        }
    }
}

public enum TerminalJump {
    /// `TERM_PROGRAM` values, as their hosts set them, mapped to bundle identifiers.
    public static let bundleIds: [String: String] = [
        "iTerm.app": "com.googlecode.iterm2",
        "Apple_Terminal": "com.apple.Terminal",
        "ghostty": "com.mitchellh.ghostty",
        "Ghostty": "com.mitchellh.ghostty",
        "WarpTerminal": "dev.warp.Warp-Stable",
        "WezTerm": "com.github.wez.wezterm",
        "kitty": "net.kovidgoyal.kitty",
        "alacritty": "org.alacritty",
        "Alacritty": "org.alacritty",
        "Hyper": "co.zeit.hyper",
        "tabby": "org.tabby",
        "rio": "com.raphaelamorim.rio",
        "vscode": "com.microsoft.VSCode",
        "cursor": "com.todesktop.230313mzl4w4u92",
        "windsurf": "com.exafunction.windsurf",
        "zed": "dev.zed.Zed",
        "Zed": "dev.zed.Zed",
    ]

    private static let displayNames: [String: String] = [
        "com.googlecode.iterm2": "iTerm",
        "com.apple.Terminal": "Terminal",
        "com.mitchellh.ghostty": "Ghostty",
        "dev.warp.Warp-Stable": "Warp",
        "com.github.wez.wezterm": "WezTerm",
        "net.kovidgoyal.kitty": "kitty",
        "org.alacritty": "Alacritty",
        "com.microsoft.VSCode": "VS Code",
        "com.todesktop.230313mzl4w4u92": "Cursor",
        "com.exafunction.windsurf": "Windsurf",
        "dev.zed.Zed": "Zed",
    ]

    /// URL schemes the editors register. Perch's extension answers
    /// `<scheme>://kweli.perch-jump/focus?tty=…` inside whichever one is running.
    static let editorSchemes: [String: String] = [
        "com.microsoft.VSCode": "vscode",
        "com.todesktop.230313mzl4w4u92": "cursor",
        "com.exafunction.windsurf": "windsurf",
    ]

    public static func name(forBundle bundleId: String) -> String {
        displayNames[bundleId] ?? bundleId
    }

    /// The URI that focuses the right tab, once the extension is installed there.
    public static func editorURL(for target: JumpTarget) -> URL? {
        guard case .editorURI(_, let scheme, let tty) = target else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = "kweli.perch-jump"
        components.path = "/focus"
        components.queryItems = [URLQueryItem(name: "tty", value: tty)]
        return components.url
    }

    /// Which app hosts this session, when we can tell.
    public static func bundleId(for client: ClientInfo?) -> String? {
        client?.terminal.flatMap { bundleIds[$0] }
    }

    public static func plan(for client: ClientInfo?) -> JumpPlan {
        guard let client, let terminal = client.terminal,
            let bundleId = bundleIds[terminal]
        else {
            return JumpPlan(target: .unavailable, tmuxPane: client?.tmuxPane)
        }

        switch bundleId {
        case "com.googlecode.iterm2":
            // `w0t1p0:UUID` — iTerm's own session id, which its AppleScript dictionary
            // matches directly.
            if let session = client.session, !session.isEmpty {
                return JumpPlan(target: .iTerm(bundleId: bundleId, session: session),
                                tmuxPane: client.tmuxPane)
            }
        case "com.apple.Terminal":
            if let tty = client.tty, !tty.isEmpty {
                return JumpPlan(target: .appleTerminal(bundleId: bundleId, tty: tty),
                                tmuxPane: client.tmuxPane)
            }
        case "net.kovidgoyal.kitty":
            // `KITTY_WINDOW_ID` is set in every kitty window's environment, and remote
            // control addresses windows by exactly that id.
            if let id = client.session, !id.isEmpty {
                return JumpPlan(
                    target: .remoteControl(
                        bundleId: bundleId, executable: "kitty",
                        arguments: ["@", "focus-window", "--match", "id:\(id)"]),
                    tmuxPane: client.tmuxPane)
            }
        case "com.github.wez.wezterm":
            // WezTerm needs no configuration for this — `wezterm cli` talks to the running
            // instance out of the box.
            if let pane = client.session, !pane.isEmpty {
                return JumpPlan(
                    target: .remoteControl(
                        bundleId: bundleId, executable: "wezterm",
                        arguments: ["cli", "activate-pane", "--pane-id", pane]),
                    tmuxPane: client.tmuxPane)
            }
        default:
            // VS Code and its forks each register their own scheme, and each needs its own
            // copy of the extension — they do not share an extension host.
            if let scheme = editorSchemes[bundleId], let tty = client.tty, !tty.isEmpty {
                return JumpPlan(
                    target: .editorURI(bundleId: bundleId, scheme: scheme, tty: tty),
                    tmuxPane: client.tmuxPane)
            }
        }

        return JumpPlan(target: .activate(bundleId: bundleId), tmuxPane: client.tmuxPane)
    }

    /// AppleScript that focuses the exact iTerm2 session, or does nothing if it has since
    /// been closed. Written to fail quietly: a jump that misses must not raise a dialog.
    public static func script(for target: JumpTarget) -> String? {
        switch target {
        case .iTerm(_, let session):
            let escaped = escape(session)
            return """
                tell application "iTerm2"
                  repeat with w in windows
                    repeat with t in tabs of w
                      repeat with s in sessions of t
                        if id of s is "\(escaped)" then
                          select w
                          select t
                          select s
                          activate
                          return
                        end if
                      end repeat
                    end repeat
                  end repeat
                  activate
                end tell
                """
        case .appleTerminal(_, let tty):
            let escaped = escape(tty)
            return """
                tell application "Terminal"
                  repeat with w in windows
                    repeat with t in tabs of w
                      if tty of t is "\(escaped)" then
                        set selected of t to true
                        set index of w to 1
                        activate
                        return
                      end if
                    end repeat
                  end repeat
                  activate
                end tell
                """
        case .editorURI, .remoteControl, .activate, .unavailable:
            return nil
        }
    }

    /// AppleScript string literals only need these two escaped, and doing it by hand keeps
    /// a session id from ever being able to close the quote and inject.
    static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
