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

/// Approving a plan is the one allow that must carry both halves.
///
/// `ExitPlanMode` declares `requiresUserInteraction()`, and Claude Code drops an `allow`
/// with no `updatedInput` for such a tool — it prompts in the terminal as if the hook had
/// said nothing, which is what Approve used to do. The `setMode` is the second half: an
/// approval that names no mode leaves the session in `plan`, where every edit is refused.
/// Verified against the `hookSpecificOutput` schemas in Claude Code 2.1.220.
@Test func planApprovalCarriesTheInputAndTheMode() throws {
    let plan = try JSONDecoder().decode(
        JSONValue.self, from: #"{"plan": "1. do it"}"#.data(using: .utf8)!)
    let body = try specific(
        of: HookOutput(
            event: "PermissionRequest", decision: .allow, reason: nil,
            updatedInput: plan, planMode: .bypassPermissions))

    let decision = try #require(body["decision"] as? [String: Any])
    #expect(decision["behavior"] as? String == "allow")
    let updated = try #require(decision["updatedInput"] as? [String: Any])
    #expect(updated["plan"] as? String == "1. do it")

    let updates = try #require(decision["updatedPermissions"] as? [[String: Any]])
    #expect(updates.count == 1)
    #expect(updates.first?["type"] as? String == "setMode")
    #expect(updates.first?["mode"] as? String == "bypassPermissions")
    #expect(updates.first?["destination"] as? String == "session")
}

/// The exact bytes `perch-hook` prints for an approved plan — local and remote hooks both
/// echo this, so it is the contract in full.
@Test func theApprovedPlanBytes() throws {
    let plan = try JSONDecoder().decode(
        JSONValue.self, from: #"{"plan": "1. do it"}"#.data(using: .utf8)!)
    let response = PerchResponse(decision: .allow, updatedInput: plan, planMode: .default)
    let data = try #require(response.renderedOutput(event: "PermissionRequest"))
    // Key order out of `JSONEncoder` is not stable; the shape is what is being pinned.
    let canonical = try JSONSerialization.data(
        withJSONObject: try JSONSerialization.jsonObject(with: data), options: [.sortedKeys])

    #expect(
        String(decoding: canonical, as: UTF8.self) == """
            {"hookSpecificOutput":{"decision":{"behavior":"allow",\
            "updatedInput":{"plan":"1. do it"},\
            "updatedPermissions":[{"destination":"session","mode":"default",\
            "type":"setMode"}]},"hookEventName":"PermissionRequest"}}
            """)
}

/// The three modes Claude Code's own plan prompt offers for continuing in place, spelled
/// the way its permission-mode enum spells them. A typo here is silent: the update is
/// rejected and the session stays in plan mode.
@Test func planModesAreSpelledTheWayClaudeCodeSpellsThem() throws {
    let modes = try PlanMode.allCases.map { mode -> String in
        let body = try specific(
            of: HookOutput(
                event: "PermissionRequest", decision: .allow, reason: nil, planMode: mode))
        let decision = try #require(body["decision"] as? [String: Any])
        let updates = try #require(decision["updatedPermissions"] as? [[String: Any]])
        return try #require(updates.first?["mode"] as? String)
    }

    #expect(modes == ["default", "acceptEdits", "bypassPermissions"])
}

/// A remembered rule and a plan mode are different entries in the same list, and neither
/// may overwrite the other.
@Test func aRuleAndAModeBothLandInUpdatedPermissions() throws {
    let body = try specific(
        of: HookOutput(
            event: "PermissionRequest", decision: .allow, reason: nil,
            rule: RememberedRule(toolName: "Bash", content: nil), planMode: .default))

    let decision = try #require(body["decision"] as? [String: Any])
    let updates = try #require(decision["updatedPermissions"] as? [[String: Any]])
    #expect(updates.map { $0["type"] as? String } == ["setMode", "addRules"])
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

/// A verbatim `Stop` payload, captured from a real session that had delegated work.
///
/// This is the field the whole `background` state rests on, and it is one Claude Code
/// could rename without anything else here noticing: the session would simply go back to
/// reporting itself finished the moment it launched an agent. Pinning the real shape is
/// what turns that into a failing test rather than a silent regression.
@Test func aStopPayloadCarriesWhatTheTurnLeavesRunning() throws {
    let json = """
        {"session_id":"9cc93930","transcript_path":"/x.jsonl","cwd":"/tmp/x",
         "hook_event_name":"Stop","permission_mode":"bypassPermissions",
         "background_tasks":[
           {"id":"abd19c96","type":"subagent","status":"running",
            "description":"Count lines in sample.txt","agent_type":"general-purpose"},
           {"id":"brnr1bpcp","type":"shell","status":"running",
            "description":"Run sleep then echo","command":"sleep 25 && echo done"}],
         "session_crons":[]}
        """
    let payload = try JSONDecoder().decode(ClaudeHookPayload.self, from: Data(json.utf8))
    let tasks = try #require(payload.backgroundTasks)

    #expect(tasks.count == 2)
    #expect(tasks.filter(\.isRunning).count == 2)
    #expect(tasks[0].isSubagent)
    // The description, not the agent type: "Count lines in sample.txt" says more on a card
    // than "general-purpose" does.
    #expect(tasks[0].displayName == "Count lines in sample.txt")
    #expect(tasks[1].isSubagent == false)
    #expect(tasks[1].command == "sleep 25 && echo done")

    // And a turn with nothing left running says so explicitly, rather than by omission.
    let done = try JSONDecoder().decode(
        ClaudeHookPayload.self, from: Data(#"{"background_tasks":[]}"#.utf8))
    let empty = try #require(done.backgroundTasks)
    #expect(empty.isEmpty)

    // A CLI that sends no such field is not the same as one reporting nothing running.
    let silent = try JSONDecoder().decode(ClaudeHookPayload.self, from: Data("{}".utf8))
    #expect(silent.backgroundTasks == nil)
}

/// The subagent's own id, on the events that are about it and on the tool calls it makes —
/// which arrive under the parent's session id and are otherwise indistinguishable from the
/// main agent's own work.
@Test func aSubagentsEventsCarryItsId() throws {
    let json = """
        {"session_id":"9cc93930","agent_id":"abd19c96","agent_type":"general-purpose",
         "hook_event_name":"PreToolUse","tool_name":"Bash"}
        """
    let payload = try JSONDecoder().decode(ClaudeHookPayload.self, from: Data(json.utf8))

    #expect(payload.agentId == "abd19c96")
    #expect(payload.sessionId == "9cc93930")
    let request = PerchRequest(
        token: "t", event: "PreToolUse", wantsDecision: false, payload: payload)
    #expect(request.subagentLabel == "general-purpose")
}
