import Foundation
import Testing

@testable import PerchKit

private let epoch = Date(timeIntervalSince1970: 1_700_000_000)
private func later(_ seconds: TimeInterval) -> Date { epoch.addingTimeInterval(seconds) }

private func request(
    event: String = "PreToolUse",
    session: String = "abc",
    command: String = "ls",
    source: String? = nil
) -> PerchRequest {
    var payload = ClaudeHookPayload()
    payload.sessionId = session
    payload.hookEventName = event
    payload.toolName = "Bash"
    payload.toolInput = .object(["command": .string(command)])

    // The raw payload is what both hook copies were handed, byte for byte.
    let raw = JSONValue.object([
        "session_id": .string(session),
        "hook_event_name": .string(event),
        "tool_name": .string("Bash"),
        "tool_input": .object(["command": .string(command)]),
    ])

    return PerchRequest(
        token: "t", event: event, wantsDecision: event == "PermissionRequest",
        payload: payload, raw: raw,
        // Deliberately different between the two copies: the project entry predates
        // `--source`, the global one carries it. Neither may change the key.
        client: ClientInfo(terminal: "ghostty"), agent: Agent(source: source))
}

/// The case this exists for: the same event, delivered once per hook entry that matched
/// it, because Claude Code merges the global and project settings and runs both.
@Test func twoHookInstallsProduceOneKey() {
    let fromProject = request(source: nil)
    let fromGlobal = request(source: "claude")

    #expect(fromProject.duplicateKey != nil)
    #expect(fromProject.duplicateKey == fromGlobal.duplicateKey)
}

@Test func differentWorkIsNotADuplicate() {
    #expect(request(command: "ls").duplicateKey != request(command: "rm -rf /").duplicateKey)
    #expect(request(session: "a").duplicateKey != request(session: "b").duplicateKey)
    #expect(
        request(event: "PreToolUse").duplicateKey != request(event: "PostToolUse").duplicateKey)
}

/// Nothing to key on means no key: treating every unreadable payload as the same event
/// would drop real rows, which is worse than the doubling this is meant to fix.
@Test func anEmptyPayloadHasNoKey() {
    let bare = PerchRequest(
        token: "t", event: "Stop", wantsDecision: false, payload: ClaudeHookPayload())
    #expect(bare.duplicateKey == nil)
}

// `admit` mutates, and #expect cannot call a mutating member inline, so each answer is
// taken first and asserted after.
@Test func theSecondCopyIsRejectedAndTheFirstIsNot() {
    var filter = DuplicateFilter(window: 2)
    let first = filter.admit("k", at: epoch)
    let copy = filter.admit("k", at: later(0.01))
    let unrelated = filter.admit("other", at: later(0.01))

    #expect(first)
    #expect(!copy)
    #expect(unrelated)
}

/// A tool you genuinely ran twice still gets its own row, once the copy window is past.
@Test func aRepeatAfterTheWindowIsAdmitted() {
    var filter = DuplicateFilter(window: 2)
    let first = filter.admit("k", at: epoch)
    let inside = filter.admit("k", at: later(1.9))
    let outside = filter.admit("k", at: later(2.1))

    #expect(first)
    #expect(!inside)
    #expect(outside)
}

/// A repeat must not extend the window: otherwise a key arriving steadily every second
/// would be suppressed for as long as it kept arriving.
@Test func aRejectedCopyDoesNotPushTheWindowBack() {
    var filter = DuplicateFilter(window: 2)
    let first = filter.admit("k", at: epoch)
    let copy = filter.admit("k", at: later(1.5))
    let afterWindow = filter.admit("k", at: later(2.5))

    #expect(first)
    #expect(!copy)
    #expect(afterWindow)
}
