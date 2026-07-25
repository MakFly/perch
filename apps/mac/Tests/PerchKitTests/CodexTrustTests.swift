import Foundation
import Testing

@testable import PerchKit

@Test func eventNamesAreSpelledTheWayCodexRecordsThem() {
    #expect(CodexTrust.stateKeyEvent("PreToolUse") == "pre_tool_use")
    #expect(CodexTrust.stateKeyEvent("PermissionRequest") == "permission_request")
    #expect(CodexTrust.stateKeyEvent("Stop") == "stop")
    #expect(CodexTrust.stateKeyEvent("UserPromptSubmit") == "user_prompt_submit")
}

/// Only Perch's own entries count — a file full of other people's hooks must not read as
/// "Perch is installed".
@Test func onlyPerchEntriesAreCounted() {
    let hooks = """
        {"hooks": {
          "PreToolUse": [
            {"matcher": "", "hooks": [
               {"type": "command", "command": "/other/tool"},
               {"type": "command", "command": "/x/perch-hook PreToolUse --source codex"}]}],
          "Stop": [
            {"hooks": [{"type": "command", "command": "/x/perch-hook Stop --source codex"}]}]
        }}
        """.data(using: .utf8)!

    #expect(
        CodexTrust.perchPositions(inHooksFile: hooks) == ["pre_tool_use:0:1", "stop:0:0"])
}

@Test func aFileWithNoPerchHooksHasNoPositions() {
    let hooks = #"{"hooks": {"Stop": [{"hooks": [{"command": "/other"}]}]}}"#.data(using: .utf8)!
    #expect(CodexTrust.perchPositions(inHooksFile: hooks).isEmpty)
    #expect(CodexTrust.perchPositions(inHooksFile: Data("garbage".utf8)).isEmpty)
}

/// Table headers are read directly — enough to answer the question, with no TOML parser
/// to keep correct.
@Test func trustedPositionsAreReadFromTheConfigTables() {
    let config = """
        [hooks.state]

        [hooks.state."/home/.codex/hooks.json:pre_tool_use:0:1"]
        trusted_hash = "sha256:abc"

        [hooks.state."/home/.codex/hooks.json:stop:0:0"]
        trusted_hash = "sha256:def"

        [hooks.state."/elsewhere/hooks.json:stop:0:0"]
        trusted_hash = "sha256:ghi"
        """

    let trusted = CodexTrust.trustedPositions(
        inConfig: config, hooksPath: "/home/.codex/hooks.json")

    #expect(trusted == ["pre_tool_use:0:1", "stop:0:0"])
    // A different hooks file's state must not be counted as ours.
    #expect(!trusted.contains("/elsewhere/hooks.json:stop:0:0"))
}

@Test func statusIsComputedFromBothFiles() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("codex-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let hooksPath = root.appendingPathComponent("hooks.json")

    try """
        {"hooks": {"Stop": [{"hooks": [{"command": "/x/perch-hook Stop"}]}],
                   "PreToolUse": [{"hooks": [{"command": "/x/perch-hook PreToolUse"}]}]}}
        """.write(to: hooksPath, atomically: true, encoding: .utf8)

    // Only one of the two positions has been approved.
    try """
        [hooks.state."\(hooksPath.path):stop:0:0"]
        trusted_hash = "sha256:abc"
        """.write(
        to: root.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)

    let status = try #require(CodexTrust.status(codexHome: root.path))
    #expect(status.installedPositions == 2)
    #expect(status.trustedPositions == 1)
    #expect(status.needsTrust)
    #expect(!status.isFullyTrusted)

    try? FileManager.default.removeItem(at: root)
}

/// Nothing installed means nothing to report — the pane should not appear at all.
@Test func statusIsNilWhenCodexIsNotWiredUp() {
    #expect(CodexTrust.status(codexHome: "/nonexistent/codex") == nil)
}
