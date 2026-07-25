import Foundation
import Testing

@testable import PerchKit

/// The hook's stdout is a contract with Claude Code: if these keys drift, permissions
/// silently stop working — a rejected object reads exactly like a hook that said nothing.
/// The two permission events use different schemas, so pin both.
private func specific(of output: HookOutput) throws -> [String: Any] {
    let data = try JSONEncoder().encode(output)
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    return try #require(json["hookSpecificOutput"] as? [String: Any])
}

@Test func permissionRequestDenyUsesBehaviourSchema() throws {
    let body = try specific(
        of: HookOutput(event: "PermissionRequest", decision: .deny, reason: "nope"))

    #expect(body["hookEventName"] as? String == "PermissionRequest")
    let decision = try #require(body["decision"] as? [String: Any])
    #expect(decision["behavior"] as? String == "deny")
    #expect(decision["message"] as? String == "nope")
    // The PreToolUse spelling here is silently ignored by Claude Code.
    #expect(body["permissionDecision"] == nil)
}

@Test func permissionRequestAllowCarriesTheRememberedRule() throws {
    let rule = RememberedRule(toolName: "Bash", content: "npm run:*")
    let body = try specific(
        of: HookOutput(event: "PermissionRequest", decision: .allow, reason: nil, rule: rule))

    let decision = try #require(body["decision"] as? [String: Any])
    #expect(decision["behavior"] as? String == "allow")

    let updates = try #require(decision["updatedPermissions"] as? [[String: Any]])
    let update = try #require(updates.first)
    #expect(update["type"] as? String == "addRules")
    #expect(update["behavior"] as? String == "allow")
    #expect(update["destination"] as? String == "localSettings")

    let rules = try #require(update["rules"] as? [[String: Any]])
    #expect(rules.first?["toolName"] as? String == "Bash")
    #expect(rules.first?["ruleContent"] as? String == "npm run:*")
}

/// A plain allow must not carry an empty rule list — that would be a schema violation.
@Test func permissionRequestAllowWithoutRuleOmitsPermissions() throws {
    let body = try specific(
        of: HookOutput(event: "PermissionRequest", decision: .allow, reason: nil))
    let decision = try #require(body["decision"] as? [String: Any])
    #expect(decision["behavior"] as? String == "allow")
    #expect(decision["updatedPermissions"] == nil)
}

@Test func preToolUseKeepsTheLegacySchema() throws {
    let body = try specific(
        of: HookOutput(event: "PreToolUse", decision: .deny, reason: "nope"))

    #expect(body["permissionDecision"] as? String == "deny")
    #expect(body["permissionDecisionReason"] as? String == "nope")
    #expect(body["decision"] == nil)
}

/// The remote hook is a shell script with no JSON parser, so the Mac sends it the finished
/// stdout. Both hooks therefore emit bytes built by the same tested code.
@Test func remoteClientsGetTheFinishedOutput() throws {
    let response = PerchResponse(
        decision: .allow,
        rule: RememberedRule(toolName: "Bash", content: "npm run:*"))

    let encoded = response.renderedOutputBase64(event: "PermissionRequest")
    let data = try #require(Data(base64Encoded: encoded))
    let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let body = try #require(json["hookSpecificOutput"] as? [String: Any])
    let decision = try #require(body["decision"] as? [String: Any])

    #expect(decision["behavior"] as? String == "allow")
    #expect(decision["updatedPermissions"] != nil)
}

/// Base64's alphabet has no quote in it, which is the whole reason it is used here: a
/// `sed` match cannot run past its own field.
@Test func theEncodedOutputIsSafeToExtractWithoutAParser() {
    let response = PerchResponse(decision: .deny, reason: #"he said "no" \ then left"#)
    let encoded = response.renderedOutputBase64(event: "PermissionRequest")

    #expect(!encoded.contains("\""))
    #expect(!encoded.contains("\\"))
    #expect(Data(base64Encoded: encoded) != nil)
}

/// Deferring to Claude Code's own prompt means printing nothing at all.
@Test func anAskAnswerRendersNothing() {
    #expect(PerchResponse(decision: .ask).renderedOutput(event: "PermissionRequest") == nil)
    #expect(PerchResponse().renderedOutput(event: "PermissionRequest") == nil)
    #expect(PerchResponse(decision: .ask).renderedOutputBase64(event: "PermissionRequest") == "")
}

@Test func decodesRealHookPayload() throws {
    let raw = """
        {
          "session_id": "abc123",
          "transcript_path": "/tmp/t.jsonl",
          "cwd": "/Users/kevin/lab",
          "hook_event_name": "PermissionRequest",
          "tool_name": "Bash",
          "tool_input": {"command": "rm -rf ./dist", "description": "clean"}
        }
        """.data(using: .utf8)!

    let payload = try JSONDecoder().decode(ClaudeHookPayload.self, from: raw)

    #expect(payload.sessionId == "abc123")
    #expect(payload.toolName == "Bash")
    #expect(payload.cwd == "/Users/kevin/lab")
    #expect(payload.toolInput?["command"]?.stringValue == "rm -rf ./dist")
}

/// Unknown fields must not break decoding — Claude Code adds them over time.
@Test func toleratesUnknownFields() throws {
    let raw = """
        {"hook_event_name": "PreToolUse", "brand_new_field": {"nested": [1, true, null]}}
        """.data(using: .utf8)!

    let payload = try JSONDecoder().decode(ClaudeHookPayload.self, from: raw)
    #expect(payload.hookEventName == "PreToolUse")

    let value = try JSONDecoder().decode(JSONValue.self, from: raw)
    #expect(value["brand_new_field"] != nil)
}

@Test func requestRoundTripsThroughJSON() throws {
    var payload = ClaudeHookPayload()
    payload.toolName = "Write"
    payload.sessionId = "s1"

    let request = PerchRequest(
        token: "t", event: "PermissionRequest", wantsDecision: true, payload: payload)
    let data = try JSONEncoder().encode(request)
    let decoded = try JSONDecoder().decode(PerchRequest.self, from: data)

    #expect(decoded.token == "t")
    #expect(decoded.wantsDecision)
    #expect(decoded.payload.toolName == "Write")
    #expect(decoded.v == Wire.protocolVersion)
}

/// The key a `SubagentStart` uses has moved between Claude Code releases, and a fan-out
/// `Task` spells it differently from an Agent Team member. Nothing here is load-bearing —
/// a subagent with no label is still a subagent — so this reads whichever one is there.
@Test func aSubagentLabelIsReadFromWhicheverKeyCarriesIt() {
    func request(_ json: String) -> PerchRequest {
        let raw = try? JSONDecoder().decode(JSONValue.self, from: Data(json.utf8))
        var payload = ClaudeHookPayload()
        payload.toolInput = raw?["tool_input"]
        return PerchRequest(
            token: "t", event: "SubagentStart", wantsDecision: false, payload: payload, raw: raw)
    }

    #expect(
        request(#"{"tool_input": {"subagent_type": "code-reviewer"}}"#).subagentLabel
            == "code-reviewer")
    #expect(request(#"{"agent_type": "explorer"}"#).subagentLabel == "explorer")
    #expect(
        request(#"{"tool_input": {"description": "audit the API"}}"#).subagentLabel
            == "audit the API")
    #expect(request(#"{"unrelated": "value"}"#).subagentLabel == nil)
}
