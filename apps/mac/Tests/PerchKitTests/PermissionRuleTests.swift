import Foundation
import Testing

@testable import PerchKit

/// A too-generous rule is a silent, permanent grant, so the prefix logic is the most
/// safety-critical pure function in the project.
@Test(arguments: [
    ("npm run build", "npm run"),
    ("npm run build --silent", "npm run"),
    ("git status", "git status"),
    ("ls", "ls"),
    ("cargo test --release", "cargo test"),
])
func commandPrefixKeepsTwoLeadingTokens(command: String, expected: String) {
    #expect(PermissionRule.commandPrefix(command) == expected)
}

/// Approving `npm run build && rm -rf /` must never produce a rule that also covers the
/// `rm`: the prefix stops at the shell separator.
@Test(arguments: [
    "npm run build && rm -rf /",
    "npm run build; rm -rf /",
    "npm run build | tee log",
    "npm run build $(rm -rf /)",
])
func commandPrefixStopsAtShellSeparators(command: String) {
    let prefix = PermissionRule.commandPrefix(command)
    #expect(prefix == "npm run")
    #expect(!(prefix ?? "").contains("rm"))
}

/// Paths and flags are per-invocation detail, not part of a reusable rule.
@Test func commandPrefixStopsAtPathsAndFlags() {
    #expect(PermissionRule.commandPrefix("cat /etc/passwd") == "cat")
    #expect(PermissionRule.commandPrefix("rm -rf ./dist") == "rm")
    #expect(PermissionRule.commandPrefix("ls *.swift") == "ls")
    #expect(PermissionRule.commandPrefix("") == nil)
    #expect(PermissionRule.commandPrefix("   ") == nil)
}

@Test func bashRulesAreScopedToTheCommandPrefix() throws {
    var payload = ClaudeHookPayload()
    payload.toolName = "Bash"
    payload.toolInput = .object(["command": .string("npm run build --silent")])
    let request = PerchRequest(
        token: "t", event: "PermissionRequest", wantsDecision: true, payload: payload)

    #expect(PermissionRule.rule(for: request) == "Bash(npm run:*)")
}

@Test func nonBashToolsGetToolScopedRules() {
    var payload = ClaudeHookPayload()
    payload.toolName = "Read"
    payload.toolInput = .object(["file_path": .string("/tmp/x")])
    let request = PerchRequest(
        token: "t", event: "PermissionRequest", wantsDecision: true, payload: payload)

    #expect(PermissionRule.rule(for: request) == "Read")
}

/// No tool name, or a Bash call without a command, means no rule we can vouch for —
/// the UI then hides the "Always" button entirely.
@Test func noRuleWhenWeCannotExpressOneSafely() {
    var payload = ClaudeHookPayload()
    let noTool = PerchRequest(
        token: "t", event: "PermissionRequest", wantsDecision: true, payload: payload)
    #expect(PermissionRule.rule(for: noTool) == nil)

    payload.toolName = "Bash"
    payload.toolInput = .object([:])
    let noCommand = PerchRequest(
        token: "t", event: "PermissionRequest", wantsDecision: true, payload: payload)
    #expect(PermissionRule.rule(for: noCommand) == nil)
}

@Test func persistIsIdempotentAndPreservesExistingSettings() throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("perch-rule-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let claude = directory.appendingPathComponent(".claude")
    try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
    let settings = claude.appendingPathComponent("settings.local.json")
    try Data(#"{"model":"opus","permissions":{"allow":["Read"]}}"#.utf8).write(to: settings)

    #expect(PermissionRule.persist("Bash(npm run:*)", inProjectAt: directory.path))
    #expect(PermissionRule.persist("Bash(npm run:*)", inProjectAt: directory.path))

    let root = try #require(
        try JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
    let permissions = try #require(root["permissions"] as? [String: Any])
    let allow = try #require(permissions["allow"] as? [String])

    #expect(allow == ["Read", "Bash(npm run:*)"])
    #expect(root["model"] as? String == "opus")
}
