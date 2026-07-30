import Foundation
import Testing

@testable import PerchKit

// MARK: - Timestamp

/// The hand-rolled parser replaces ISO8601DateFormatter, so it has to agree with it.
@Test(arguments: [
    "2026-07-25T11:07:27.354Z",
    "2026-01-01T00:00:00.000Z",
    "2026-12-31T23:59:59.999Z",
    "2024-02-29T12:00:00.000Z",  // leap day
    "2026-03-01T00:00:00.000Z",  // day after February in a non-leap year
])
func timestampParserMatchesFoundation(text: String) throws {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

    let expected = try #require(formatter.date(from: text))
    let actual = try #require(TranscriptParser.parseTimestamp(text))

    #expect(abs(actual.timeIntervalSince1970 - expected.timeIntervalSince1970) < 0.001)
}

@Test func timestampParserRejectsGarbage() {
    #expect(TranscriptParser.parseTimestamp("") == nil)
    #expect(TranscriptParser.parseTimestamp("not-a-date") == nil)
    #expect(TranscriptParser.parseTimestamp("2026-07-25") == nil)
    #expect(TranscriptParser.parseTimestamp("2026-13-25T11:07:27.354Z") == nil)
}

// MARK: - Parsing

private let usageLine = """
    {"type":"assistant","requestId":"req_1","timestamp":"2026-07-25T11:07:27.354Z",\
    "sessionId":"s1","cwd":"/tmp","message":{"id":"msg_1","model":"claude-opus-4-8",\
    "usage":{"input_tokens":2,"output_tokens":552,"cache_read_input_tokens":16847,\
    "cache_creation_input_tokens":16483,\
    "cache_creation":{"ephemeral_1h_input_tokens":16483,"ephemeral_5m_input_tokens":0},\
    "iterations":[{"input_tokens":2,"output_tokens":552,"cache_read_input_tokens":16847,\
    "cache_creation_input_tokens":16483}]}}}
    """

@Test func parsesUsageAndSplitsCacheByTTL() throws {
    let event = try #require(TranscriptParser.parse(line: Data(usageLine.utf8)))

    #expect(event.messageId == "msg_1")
    #expect(event.requestId == "req_1")
    #expect(event.model == "claude-opus-4-8")
    #expect(event.inputTokens == 2)
    #expect(event.outputTokens == 552)
    #expect(event.cacheReadTokens == 16847)
    #expect(event.cacheWrite1hTokens == 16483)
    #expect(event.cacheWrite5mTokens == 0)
    #expect(event.sessionId == "s1")
}

/// `usage.iterations` restates the same tokens per internal step. Counting it would
/// double every response.
@Test func ignoresIterationsWhenCounting() throws {
    let event = try #require(TranscriptParser.parse(line: Data(usageLine.utf8)))
    #expect(event.totalTokens == 2 + 552 + 16847 + 16483)
}

@Test func skipsNonAssistantAndUsagelessLines() {
    #expect(TranscriptParser.parse(line: Data(#"{"type":"user","message":{}}"#.utf8)) == nil)
    #expect(
        TranscriptParser.parse(
            line: Data(#"{"type":"assistant","message":{"id":"m","model":"x"}}"#.utf8)) == nil)
    #expect(TranscriptParser.parse(line: Data("not json".utf8)) == nil)
}

@Test func prefilterMatchesTheParser() {
    #expect(TranscriptParser.mightContainUsage(usageLine))
    #expect(!TranscriptParser.mightContainUsage(#"{"type":"user","message":{}}"#))
}

// MARK: - Pricing

@Test func pricesCacheAsMultiplesOfInput() throws {
    let opus = try #require(Pricing.pricing(for: "claude-opus-4-8"))
    #expect(opus.inputPerMillion == 5)
    #expect(opus.outputPerMillion == 25)
    #expect(opus.cacheReadPerMillion == 0.5)  // 0.1x
    #expect(opus.cacheWrite5mPerMillion == 6.25)  // 1.25x
    #expect(opus.cacheWrite1hPerMillion == 10)  // 2x
}

/// Dated snapshots and aliases must both resolve, or a whole model silently costs zero.
@Test(arguments: [
    ("claude-haiku-4-5-20251001", 1.0),
    ("claude-haiku-4-5", 1.0),
    ("claude-opus-4-8", 5.0),
    ("claude-opus-5", 5.0),
    ("claude-sonnet-5", 3.0),
    ("claude-sonnet-4-6", 3.0),
    ("claude-fable-5", 10.0),
    ("haiku", 1.0),
])
func resolvesModelIdsSeenInTranscripts(model: String, expectedInput: Double) throws {
    let pricing = try #require(Pricing.pricing(for: model), "no price for \(model)")
    #expect(pricing.inputPerMillion == expectedInput)
}

@Test func unknownModelsCostNothingRatherThanCrashing() {
    #expect(Pricing.pricing(for: "<synthetic>") == nil)
    let event = UsageEvent(
        messageId: "m", requestId: "r", timestamp: .now, model: "<synthetic>",
        inputTokens: 100, outputTokens: 100, cacheReadTokens: 0,
        cacheWrite5mTokens: 0, cacheWrite1hTokens: 0)
    #expect(Pricing.cost(of: event) == 0)
}

@Test func costUsesTheRightRateForEachTokenClass() throws {
    let event = UsageEvent(
        messageId: "m", requestId: "r", timestamp: .now, model: "claude-opus-4-8",
        inputTokens: 1_000_000,
        outputTokens: 1_000_000,
        cacheReadTokens: 1_000_000,
        cacheWrite5mTokens: 1_000_000,
        cacheWrite1hTokens: 1_000_000)

    // 5 + 25 + 0.5 + 6.25 + 10
    #expect(abs(Pricing.cost(of: event) - 46.75) < 0.0001)
}

// MARK: - Store

private func makeStore() throws -> (UsageStore, URL) {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("perch-usage-\(UUID().uuidString).sqlite")
    return (try UsageStore(path: url.path), url)
}

private func sampleEvent(id: String, request: String = "r1", tokens: Int = 100) -> UsageEvent {
    UsageEvent(
        messageId: id, requestId: request, timestamp: .now, model: "claude-opus-4-8",
        inputTokens: tokens, outputTokens: 0, cacheReadTokens: 0,
        cacheWrite5mTokens: 0, cacheWrite1hTokens: 0)
}

/// The single most important property in the project: transcripts repeat 56% of their
/// usage lines, so re-indexing must never inflate totals.
@Test func insertingTheSameEventTwiceCountsItOnce() throws {
    let (store, url) = try makeStore()
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(try store.insert([sampleEvent(id: "a")]) == 1)
    #expect(try store.insert([sampleEvent(id: "a")]) == 0)
    #expect(try store.insert([sampleEvent(id: "a"), sampleEvent(id: "b")]) == 1)

    let totals = try store.totals()
    #expect(totals.events == 2)
    #expect(totals.inputTokens == 200)
}

/// Two agents share one table, told apart by the only thing that already distinguishes
/// them: nothing but Claude Code writes `claude-*`. The regression this guards is the
/// Claude tab quietly counting Codex tokens.
@Test func eachAgentSeesOnlyItsOwnRows() throws {
    let (store, url) = try makeStore()
    defer { try? FileManager.default.removeItem(at: url) }

    var codex = sampleEvent(id: "gpt", tokens: 30)
    codex.model = "gpt-5.6-terra"
    _ = try store.insert([sampleEvent(id: "claude", tokens: 100), codex])

    #expect(try store.totals(agent: .claude).inputTokens == 100)
    #expect(try store.totals(agent: .codex).inputTokens == 30)
    // No filter is still the whole machine, which is what the diagnostics report.
    #expect(try store.totals().inputTokens == 130)

    #expect(try store.totalsByModel(agent: .codex).map(\.model) == ["gpt-5.6-terra"])
    #expect(try store.buckets(.day, limit: 10, agent: .claude).count == 1)

    #expect(try store.hasUsage(for: .codex))
}

/// Zero is not a price, it is the absence of one — and it reads on screen as "free".
/// Codex arrived exactly this way: rollouts indexed against a list that only carried
/// Anthropic, every row stored at nothing.
@Test func rowsIndexedBeforeTheirPriceWasKnownAreCorrected() throws {
    let (store, url) = try makeStore()
    defer { try? FileManager.default.removeItem(at: url) }

    var unpriced = sampleEvent(id: "gpt", tokens: 1_000_000)
    unpriced.model = "gpt-not-in-any-list"
    var priced = sampleEvent(id: "claude", tokens: 1_000_000)
    _ = try store.insert([unpriced, priced])

    let before = try store.totals()
    #expect(before.cost > 0)  // the Claude row was priced on the way in

    _ = try store.repriceUnpriced { model in
        model == "gpt-not-in-any-list" ? ModelPricing(input: 2, output: 8) : nil
    }

    // A million input tokens at $2 per million.
    #expect(try store.totals(agent: .codex).cost == 2)
    // And the row that already had a price is left exactly as it was found.
    #expect(try store.totals(agent: .claude).cost == before.cost)
}

/// The selector only appears once there is a second agent to switch to; on a machine that
/// has only ever run Claude Code it would be a control with one setting.
@Test func aClaudeOnlyMachineHasNoCodexUsage() throws {
    let (store, url) = try makeStore()
    defer { try? FileManager.default.removeItem(at: url) }

    _ = try store.insert([sampleEvent(id: "claude")])
    #expect(try store.hasUsage(for: .claude))
    #expect(try !store.hasUsage(for: .codex))
}

/// Same message id, different request id: a genuine retry, and two billed responses.
@Test func sameMessageWithDifferentRequestIsNotADuplicate() throws {
    let (store, url) = try makeStore()
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(try store.insert([sampleEvent(id: "a", request: "r1")]) == 1)
    #expect(try store.insert([sampleEvent(id: "a", request: "r2")]) == 1)
    #expect(try store.totals().events == 2)
}

@Test func bucketsGroupByGranularity() throws {
    let (store, url) = try makeStore()
    defer { try? FileManager.default.removeItem(at: url) }

    let day = Date(timeIntervalSince1970: 1_800_000_000)
    let events = (0..<3).map { index in
        UsageEvent(
            messageId: "m\(index)", requestId: "r", timestamp: day.addingTimeInterval(Double(index)),
            model: "claude-opus-4-8", inputTokens: 10, outputTokens: 0, cacheReadTokens: 0,
            cacheWrite5mTokens: 0, cacheWrite1hTokens: 0)
    }
    try store.insert(events)

    let daily = try store.buckets(.day, limit: 10)
    #expect(daily.count == 1)
    #expect(daily.first?.tokens == 30)
}

@Test func cursorsSurviveRoundTrip() throws {
    let (store, url) = try makeStore()
    defer { try? FileManager.default.removeItem(at: url) }

    #expect(store.cursor(forPath: "/tmp/a.jsonl") == nil)
    try store.setCursor(UsageStore.Cursor(offset: 42, inode: 7), forPath: "/tmp/a.jsonl")
    #expect(store.cursor(forPath: "/tmp/a.jsonl")?.offset == 42)

    try store.setCursor(UsageStore.Cursor(offset: 99, inode: 7), forPath: "/tmp/a.jsonl")
    #expect(store.cursor(forPath: "/tmp/a.jsonl")?.offset == 99)
}

// MARK: - Indexer

@Test func indexerResumesFromWhereItStopped() throws {
    let (store, storeURL) = try makeStore()
    defer { try? FileManager.default.removeItem(at: storeURL) }

    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("perch-transcripts-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let transcript = root.appendingPathComponent("session.jsonl")
    func line(_ id: String) -> String {
        usageLine.replacingOccurrences(of: #""id":"msg_1""#, with: #""id":"\#(id)""#)
            .replacingOccurrences(of: #""requestId":"req_1""#, with: #""requestId":"req_\#(id)""#)
    }

    try (line("a") + "\n").write(to: transcript, atomically: true, encoding: .utf8)
    let indexer = UsageIndexer(store: store, root: root)

    #expect(try indexer.indexAll().eventsInserted == 1)
    // Nothing new to read.
    #expect(try indexer.indexAll().eventsInserted == 0)

    // Append a second entry; only that one should be read.
    let handle = try FileHandle(forWritingTo: transcript)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((line("b") + "\n").utf8))
    try handle.close()

    #expect(try indexer.indexAll().eventsInserted == 1)
    #expect(try store.totals().events == 2)
}

/// A partial final line must not be parsed or counted as consumed, or the entry is lost
/// when the rest of it arrives.
@Test func indexerWaitsForCompleteLines() throws {
    let (store, storeURL) = try makeStore()
    defer { try? FileManager.default.removeItem(at: storeURL) }

    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("perch-partial-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let transcript = root.appendingPathComponent("session.jsonl")
    let half = String(usageLine.prefix(usageLine.count / 2))
    try half.write(to: transcript, atomically: true, encoding: .utf8)

    let indexer = UsageIndexer(store: store, root: root)
    #expect(try indexer.indexAll().eventsInserted == 0)

    // Complete the line.
    let handle = try FileHandle(forWritingTo: transcript)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data((usageLine.dropFirst(half.count) + "\n").utf8))
    try handle.close()

    #expect(try indexer.indexAll().eventsInserted == 1)
}

// MARK: - Daily aggregates, for the leaderboard

/// The board publishes one row per day and model, so the store has to group by both — and
/// group in *local* time, because "today" means the user's today and a board that rolls
/// over at UTC midnight would move someone's work to the wrong day.
@Test func dailyAggregatesGroupByDayAndModel() throws {
    let (store, url) = try makeStore()
    defer { try? FileManager.default.removeItem(at: url) }

    let calendar = Calendar.current
    let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: .now)!
    let alsoNoon = noon.addingTimeInterval(120)
    let yesterday = calendar.date(byAdding: .day, value: -1, to: noon)!

    try store.insert([
        UsageEvent(
            messageId: "m1", requestId: "r1", timestamp: noon, model: "opus",
            inputTokens: 10, outputTokens: 100, cacheReadTokens: 0,
            cacheWrite5mTokens: 0, cacheWrite1hTokens: 0, sessionId: "s1"),
        UsageEvent(
            messageId: "m2", requestId: "r2", timestamp: alsoNoon, model: "opus",
            inputTokens: 5, outputTokens: 50, cacheReadTokens: 0,
            cacheWrite5mTokens: 0, cacheWrite1hTokens: 0, sessionId: "s1"),
        UsageEvent(
            messageId: "m3", requestId: "r3", timestamp: noon, model: "sonnet",
            inputTokens: 1, outputTokens: 7, cacheReadTokens: 0,
            cacheWrite5mTokens: 0, cacheWrite1hTokens: 0, sessionId: "s2"),
        UsageEvent(
            messageId: "m4", requestId: "r4", timestamp: yesterday, model: "opus",
            inputTokens: 1, outputTokens: 1, cacheReadTokens: 0,
            cacheWrite5mTokens: 0, cacheWrite1hTokens: 0, sessionId: "s3"),
    ])

    let rows = try store.dailyByModel()
    #expect(rows.count == 3)

    let today = ISO8601DateFormatter.localDay(noon)
    let opusToday = try #require(rows.first { $0.day == today && $0.model == "opus" })
    #expect(opusToday.outputTokens == 150)
    #expect(opusToday.inputTokens == 15)

    // Two sessions today, and one yesterday — counted distinctly, not summed per event.
    let activity = try store.dailyActivity()
    let todayActivity = try #require(activity.first { $0.day == today })
    #expect(todayActivity.sessions == 2)
}

/// Focus is evidence, not wall time: minutes in which something was produced. Two events a
/// couple of minutes apart are two active minutes, not the span between them.
@Test func focusCountsActiveMinutesRatherThanElapsedTime() throws {
    let (store, url) = try makeStore()
    defer { try? FileManager.default.removeItem(at: url) }

    let calendar = Calendar.current
    let start = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: .now)!

    try store.insert([
        UsageEvent(
            messageId: "a", requestId: "r", timestamp: start, model: "opus",
            inputTokens: 0, outputTokens: 1, cacheReadTokens: 0,
            cacheWrite5mTokens: 0, cacheWrite1hTokens: 0, sessionId: "s"),
        // Same minute: one minute of work, not two.
        UsageEvent(
            messageId: "b", requestId: "r", timestamp: start.addingTimeInterval(20),
            model: "opus", inputTokens: 0, outputTokens: 1, cacheReadTokens: 0,
            cacheWrite5mTokens: 0, cacheWrite1hTokens: 0, sessionId: "s"),
        // Three hours later. Wall time would say 3h; the agent worked for two minutes.
        UsageEvent(
            messageId: "c", requestId: "r", timestamp: start.addingTimeInterval(10_800),
            model: "opus", inputTokens: 0, outputTokens: 1, cacheReadTokens: 0,
            cacheWrite5mTokens: 0, cacheWrite1hTokens: 0, sessionId: "s"),
    ])

    let activity = try store.dailyActivity()
    #expect(activity.count == 1)
    #expect(activity[0].focusSeconds == 120)
}

extension ISO8601DateFormatter {
    /// `YYYY-MM-DD` in the local zone, which is how the store labels a day.
    static func localDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
