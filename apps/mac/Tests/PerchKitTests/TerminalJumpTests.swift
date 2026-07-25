import Foundation
import Testing

@testable import PerchKit

@Test func iTermJumpsToTheExactSession() {
    let plan = TerminalJump.plan(
        for: ClientInfo(terminal: "iTerm.app", session: "w0t1p0:ABC-123"))

    #expect(plan.target == .iTerm(bundleId: "com.googlecode.iterm2", session: "w0t1p0:ABC-123"))
    let script = try! #require(TerminalJump.script(for: plan.target))
    #expect(script.contains("\"w0t1p0:ABC-123\""))
    #expect(script.contains("tell application \"iTerm2\""))
}

/// Terminal.app shares no session id with the process inside it, but every tab exposes its
/// tty — which is why the hook captures one.
@Test func terminalAppJumpsByTty() {
    let plan = TerminalJump.plan(
        for: ClientInfo(terminal: "Apple_Terminal", tty: "/dev/ttys004"))

    #expect(plan.target == .appleTerminal(bundleId: "com.apple.Terminal", tty: "/dev/ttys004"))
    #expect(TerminalJump.script(for: plan.target)?.contains("tty of t is \"/dev/ttys004\"") == true)
}

/// Without the precise handle we can still bring the window forward. Pretending otherwise
/// would mean doing nothing at all.
@Test func fallsBackToActivatingTheApp() {
    #expect(
        TerminalJump.plan(for: ClientInfo(terminal: "ghostty")).target
            == .activate(bundleId: "com.mitchellh.ghostty"))
    #expect(
        TerminalJump.plan(for: ClientInfo(terminal: "iTerm.app")).target
            == .activate(bundleId: "com.googlecode.iterm2"))
    #expect(TerminalJump.script(for: .activate(bundleId: "x")) == nil)
}

/// VS Code and its forks each register their own scheme and each need their own copy of
/// the extension — they do not share an extension host.
@Test func editorsAreReachedThroughTheirOwnURIScheme() throws {
    let code = TerminalJump.plan(
        for: ClientInfo(terminal: "vscode", tty: "/dev/ttys004"))
    #expect(
        code.target
            == .editorURI(
                bundleId: "com.microsoft.VSCode", scheme: "vscode", tty: "/dev/ttys004"))

    let url = try #require(TerminalJump.editorURL(for: code.target))
    #expect(url.absoluteString == "vscode://kweli.perch-jump/focus?tty=/dev/ttys004")
    #expect(code.summary == "Jump to VS Code")

    let cursor = TerminalJump.plan(
        for: ClientInfo(terminal: "cursor", tty: "/dev/ttys001"))
    #expect(TerminalJump.editorURL(for: cursor.target)?.scheme == "cursor")
}

/// Without a tty there is nothing to hand the extension, so it falls back to the window.
@Test func anEditorWithoutATtyFallsBackToActivating() {
    let plan = TerminalJump.plan(for: ClientInfo(terminal: "vscode"))
    #expect(plan.target == .activate(bundleId: "com.microsoft.VSCode"))
    #expect(TerminalJump.editorURL(for: plan.target) == nil)
}

/// kitty and WezTerm ship remote control, which is both more precise and less fragile than
/// driving them through AppleScript they do not implement.
@Test func kittyAndWezTermAreDrivenByTheirOwnCli() {
    #expect(
        TerminalJump.plan(for: ClientInfo(terminal: "kitty", session: "42")).target
            == .remoteControl(
                bundleId: "net.kovidgoyal.kitty", executable: "kitty",
                arguments: ["@", "focus-window", "--match", "id:42"]))

    #expect(
        TerminalJump.plan(for: ClientInfo(terminal: "WezTerm", session: "7")).target
            == .remoteControl(
                bundleId: "com.github.wez.wezterm", executable: "wezterm",
                arguments: ["cli", "activate-pane", "--pane-id", "7"]))
}

/// Without the window or pane id there is nothing to address, so it falls back.
@Test func remoteControlNeedsAnIdToAddress() {
    #expect(
        TerminalJump.plan(for: ClientInfo(terminal: "kitty")).target
            == .activate(bundleId: "net.kovidgoyal.kitty"))
    #expect(TerminalJump.script(for: .remoteControl(bundleId: "x", executable: "y", arguments: [])) == nil)
}

@Test func unknownOrMissingHostsCannotBeJumpedTo() {
    #expect(TerminalJump.plan(for: nil).target == .unavailable)
    #expect(TerminalJump.plan(for: ClientInfo()).target == .unavailable)
    #expect(TerminalJump.plan(for: ClientInfo(terminal: "some-new-terminal")).target == .unavailable)
    #expect(!TerminalJump.plan(for: nil).isPossible)
}

/// The pane survives even when the terminal itself cannot be identified — reaching the
/// right tmux pane is still worth doing.
@Test func tmuxPaneIsCarriedAlongside() {
    let plan = TerminalJump.plan(
        for: ClientInfo(terminal: "ghostty", tmuxPane: "%7"))
    #expect(plan.tmuxPane == "%7")
    #expect(TerminalJump.plan(for: ClientInfo(tmuxPane: "%7")).tmuxPane == "%7")
}

/// A session id ends up inside an AppleScript string literal, so it must not be able to
/// close the quote.
@Test func scriptLiteralsAreEscaped() {
    #expect(TerminalJump.escape(#"a"b"#) == #"a\"b"#)
    #expect(TerminalJump.escape(#"a\b"#) == #"a\\b"#)

    let plan = TerminalJump.plan(
        for: ClientInfo(terminal: "iTerm.app", session: #"x" & do shell script "boom"#))
    let script = try! #require(TerminalJump.script(for: plan.target))
    #expect(!script.contains(#"is "x" & do shell script"#))
}

@Test func summariesSayWhereTheClickGoes() {
    #expect(TerminalJump.plan(for: ClientInfo(terminal: "iTerm.app", session: "s")).summary == "Jump to iTerm")
    #expect(TerminalJump.plan(for: ClientInfo(terminal: "ghostty")).summary == "Open Ghostty")
    #expect(TerminalJump.plan(for: nil).summary == "No terminal recorded")
}
