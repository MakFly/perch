import Foundation
import Testing

@testable import PerchKit

/// Real lines from `~/.codex/sessions`, trimmed to the fields that are read. The numbers
/// are the ones a session actually produced, because the whole risk here is arithmetic.
private let sessionMeta = """
    {"timestamp":"2026-07-30T12:04:24.666Z","type":"session_meta",
     "payload":{"session_id":"019fb2e9-57da-7fe0-8e09-07b209405c17",
                "cwd":"/private/tmp/probe","cli_version":"0.145.0"}}
    """

private let turnContext = """
    {"timestamp":"2026-07-30T12:04:25.001Z","type":"turn_context",
     "payload":{"turn_id":"019fb2e9-585f","cwd":"/private/tmp/probe","model":"gpt-5.6-terra"}}
    """

/// `input_tokens` 21750 of which 4992 cached, `output_tokens` 282 of which 149 reasoning.
/// `total_tokens` is 22032 — input plus output, with cached *inside* the input.
private func tokenCount(
    input: Int = 21750, cached: Int = 4992, output: Int = 282,
    totalInput: Int = 21750, at timestamp: String = "2026-07-30T12:04:31.845Z"
) -> String {
    """
    {"timestamp":"\(timestamp)","type":"event_msg",
     "payload":{"type":"token_count",
       "info":{"total_token_usage":{"input_tokens":\(totalInput),"cached_input_tokens":0,
                                    "output_tokens":9999,"total_tokens":0},
               "last_token_usage":{"input_tokens":\(input),"cached_input_tokens":\(cached),
                                   "cache_write_input_tokens":null,"output_tokens":\(output),
                                   "reasoning_output_tokens":149,"total_tokens":22032}},
       "rate_limits":{"limit_id":"codex","primary":{"used_percent":94.0,
                      "window_minutes":10080,"resets_at":1785925463},
                      "secondary":null,"plan_type":"plus"}}}
    """
}

private func read(_ lines: [String], into rollout: inout CodexRollout) -> [UsageEvent] {
    lines.compactMap { rollout.read(line: Data($0.utf8)) }
}

@Test func aTurnsCountersBecomeAnEvent() throws {
    var rollout = CodexRollout()
    let events = read([sessionMeta, turnContext, tokenCount()], into: &rollout)

    let event = try #require(events.first)
    #expect(events.count == 1)
    #expect(event.model == "gpt-5.6-terra")
    #expect(event.sessionId == "019fb2e9-57da-7fe0-8e09-07b209405c17")
    #expect(event.cwd == "/private/tmp/probe")
    #expect(event.outputTokens == 282)
}

/// The one that decides whether every number on the screen is right.
///
/// `cached_input_tokens` is a slice of `input_tokens`, not a sibling of it — on every turn
/// measured, `total_tokens == input_tokens + output_tokens`. Counting them side by side
/// would double the input and bill the cached half at ten times its rate.
@Test func cachedInputIsInsideInputRatherThanBesideIt() throws {
    var rollout = CodexRollout()
    let event = try #require(read([sessionMeta, turnContext, tokenCount()], into: &rollout).first)

    #expect(event.inputTokens == 21_750 - 4_992)
    #expect(event.cacheReadTokens == 4_992)
    #expect(event.inputTokens + event.cacheReadTokens == 21_750)
    // `cache_write_input_tokens` is not recorded: whatever it counts is already inside the
    // input, and `ModelPricing` would charge Anthropic's write rate for it.
    #expect(event.cacheWriteTokens == 0)
    #expect(event.totalTokens == 21_750 + 282)
}

/// `total_token_usage` is the session so far; `last_token_usage` is this turn. Reading the
/// total would re-count every earlier turn on every line — a twenty-turn session would
/// report a couple of hundred.
@Test func theDeltaIsReadRatherThanTheRunningTotal() throws {
    var rollout = CodexRollout()
    let events = read(
        [
            sessionMeta, turnContext,
            tokenCount(input: 21_750, cached: 4_992, output: 282, totalInput: 21_750),
            tokenCount(
                input: 23_084, cached: 21_376, output: 411, totalInput: 44_834,
                at: "2026-07-30T12:05:02.100Z"),
        ], into: &rollout)

    #expect(events.count == 2)
    #expect(events[1].inputTokens == 23_084 - 21_376)
    #expect(events[1].outputTokens == 411)
}

/// A rollout carries no request id, so the pair is the session and the instant — both of
/// which survive a re-read, which is what the store's primary key needs.
@Test func twoReadingsOfTheSameLineAreTheSameEvent() throws {
    var first = CodexRollout()
    var second = CodexRollout()
    let lines = [sessionMeta, turnContext, tokenCount()]

    let a = try #require(read(lines, into: &first).first)
    let b = try #require(read(lines, into: &second).first)

    #expect(a.messageId == b.messageId)
    #expect(a.requestId == b.requestId)
    #expect(a.requestId == "2026-07-30T12:04:31.845Z")
}

/// The model belongs to the `turn_context` above the counters, and a session that switches
/// model mid-way keeps the latest.
@Test func theModelComesFromTheTurnAbove() throws {
    var rollout = CodexRollout()
    let switched = turnContext.replacingOccurrences(of: "gpt-5.6-terra", with: "gpt-5.1-codex")
    let events = read([sessionMeta, turnContext, tokenCount(), switched, tokenCount(at: "2026-07-30T12:09:00.000Z")], into: &rollout)

    #expect(events.map(\.model) == ["gpt-5.6-terra", "gpt-5.1-codex"])
}

/// Counters with no session or model above them describe nothing that can be attributed,
/// and a guess would land in the wrong column of the wrong tab.
@Test func countersWithNoContextAboveThemAreDropped() {
    var rollout = CodexRollout()
    #expect(read([tokenCount()], into: &rollout).isEmpty)
}

@Test func linesThatAreNotCountersProduceNothing() {
    var rollout = CodexRollout()
    #expect(read([sessionMeta, turnContext], into: &rollout).isEmpty)
    #expect(rollout.read(line: Data(#"{"type":"event_msg","payload":{"type":"agent_message"}}"#.utf8)) == nil)
    #expect(rollout.read(line: Data("not json".utf8)) == nil)
}

/// `token_count` outnumbers `turn_context` twenty to one, so an indexer resuming into the
/// middle of a rollout with no state would drop hundreds of turns in silence. The session
/// id is recoverable from the filename alone.
@Test func theSessionIdIsInTheFilename() {
    #expect(
        CodexRollout.sessionId(
            inFilename: "rollout-2026-07-30T14-04-24-019fb2e9-57da-7fe0-8e09-07b209405c17.jsonl")
            == "019fb2e9-57da-7fe0-8e09-07b209405c17")
    #expect(CodexRollout.sessionId(inFilename: "notes.jsonl") == nil)
    #expect(CodexRollout.sessionId(inFilename: "rollout-2026-07-30-nope.jsonl") == nil)
}

// MARK: - Quota

@Test func theRateLimitsOnACounterAreThePlansWindows() throws {
    let payload = try #require(
        try JSONSerialization.jsonObject(with: Data(tokenCount().utf8)) as? [String: Any])
    let limits = try #require(
        CodexQuota.limits(fromTokenCount: payload["payload"] as! [String: Any]))

    let window = try #require(limits.windows.first)
    #expect(limits.windows.count == 1)
    #expect(window.id == "codex_primary")
    // Codex names the window by its width and nothing else.
    #expect(window.title == "7d")
    #expect(window.window.utilization == 94)
    #expect(window.window.resetsAt == Date(timeIntervalSince1970: 1_785_925_463))
}

@Test func aWindowIsNamedByHowWideItIs() {
    #expect(CodexQuota.title(forWindowMinutes: 10_080) == "7d")
    #expect(CodexQuota.title(forWindowMinutes: 1_440) == "1d")
    #expect(CodexQuota.title(forWindowMinutes: 300) == "5h")
    #expect(CodexQuota.title(forWindowMinutes: 90) == "90m")
    #expect(CodexQuota.title(forWindowMinutes: nil) == "quota")
}

/// The newest reading wins: a rollout holds one line per turn and the last one is the
/// window as it stands now.
@Test func theLastCounterInTheFileIsTheReading() throws {
    let older = tokenCount().replacingOccurrences(of: "\"used_percent\":94.0", with: "\"used_percent\":12.0")
    let lines = [sessionMeta, turnContext, older, tokenCount()].map { Data($0.utf8) }

    let limits = try #require(CodexQuota.limits(inLines: lines))
    #expect(limits.windows.first?.window.utilization == 94)
}

@Test func aRolloutWithNoCountersHasNoQuota() {
    #expect(CodexQuota.limits(inLines: [Data(sessionMeta.utf8)]) == nil)
    #expect(CodexQuota.limits(inLines: []) == nil)
}
