import Foundation
import Testing

@testable import PerchKit

/// A real `message.data` row, trimmed to the fields that are read. The numbers are the ones
/// a session on this machine actually produced.
private func message(
    model: String = "deepseek-v4-flash-free",
    provider: String = "opencode",
    input: Int = 363,
    output: Int = 29,
    reasoning: Int = 11,
    cacheRead: Int = 21_760,
    cacheWrite: Int = 0,
    cost: Double = 0,
    created: Int = 1_785_273_371_310,
    completed: Int? = 1_785_273_372_103
) -> String {
    let time =
        completed.map { "{\"created\":\(created),\"completed\":\($0)}" }
        ?? "{\"created\":\(created)}"
    return """
        {"role":"assistant","mode":"build","agent":"build",
         "path":{"cwd":"/Users/kevin/lab/saas","root":"/Users/kevin/lab/saas"},
         "cost":\(cost),
         "tokens":{"total":0,"input":\(input),"output":\(output),"reasoning":\(reasoning),
                   "cache":{"write":\(cacheWrite),"read":\(cacheRead)}},
         "modelID":"\(model)","providerID":"\(provider)",
         "time":\(time),"finish":"stop"}
        """
}

/// Builds a database with opencode's own schema, so the reader is exercised against the
/// shape it will meet rather than against one written to suit it.
private func makeOpencodeDatabase(_ rows: [(id: String, session: String, updated: Int, data: String)])
    throws -> URL
{
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("perch-opencode-\(UUID().uuidString).db")
    let database = try SQLiteDatabase(path: url.path)
    try database.execute(
        """
        CREATE TABLE message (
            id           TEXT PRIMARY KEY,
            session_id   TEXT NOT NULL,
            time_created INTEGER NOT NULL,
            time_updated INTEGER NOT NULL,
            data         TEXT NOT NULL
        );
        """)
    try append(rows, to: url)
    return url
}

private func append(_ rows: [(id: String, session: String, updated: Int, data: String)], to url: URL)
    throws
{
    let database = try SQLiteDatabase(path: url.path)
    for row in rows {
        try database.statement(
            """
            INSERT OR REPLACE INTO message (id, session_id, time_created, time_updated, data)
            VALUES (?1, ?2, ?3, ?4, ?5)
            """
        ) { statement in
            statement.bind(1, row.id)
            statement.bind(2, row.session)
            statement.bind(3, row.updated)
            statement.bind(4, row.updated)
            statement.bind(5, row.data)
            try statement.step()
        }
    }
}

// MARK: - Reading one message

@Test func aMessageBecomesAnEventWithItsOwnModel() throws {
    let event = try #require(
        OpencodeUsage.event(id: "msg_1", sessionId: "ses_1", data: message()))

    #expect(event.agent == .opencode)
    #expect(event.messageId == "msg_1")
    #expect(event.sessionId == "ses_1")
    // The model is on the message, not on the session: opencode switches mid-session.
    #expect(event.model == "deepseek-v4-flash-free")
    #expect(event.requestId == "opencode")
    #expect(event.cwd == "/Users/kevin/lab/saas")
    #expect(abs(event.timestamp.timeIntervalSince1970 - 1_785_273_371.310) < 0.001)
}

/// The arithmetic, which is where every number on the screen is won or lost. `reasoning` is
/// inside `output` — the same trap Codex sets — and counting it beside would bill the
/// thinking twice.
@Test func reasoningIsInsideOutputRatherThanBesideIt() throws {
    let event = try #require(
        OpencodeUsage.event(id: "m", sessionId: "s", data: message(output: 29, reasoning: 11)))

    #expect(event.outputTokens == 29)
    #expect(event.totalTokens == 363 + 29 + 21_760)
}

/// opencode counts cache writes once, with no TTL to tell them apart. The 5-minute rate is
/// the conservative reading of an unlabelled write: 1.25x input rather than 2x.
@Test func cacheWritesLandOnTheCheaperRate() throws {
    let event = try #require(
        OpencodeUsage.event(id: "m", sessionId: "s", data: message(cacheWrite: 500)))

    #expect(event.cacheWrite5mTokens == 500)
    #expect(event.cacheWrite1hTokens == 0)
}

/// A turn still in flight has no counters yet. Storing it now would freeze it at zero for
/// good: `INSERT OR IGNORE` never revisits a row, so the tokens it is about to report would
/// be lost rather than late.
@Test func turnsStillRunningOrAbortedAreLeftForTheNextPass() {
    #expect(OpencodeUsage.event(id: "m", sessionId: "s", data: message(completed: nil)) == nil)
    #expect(
        OpencodeUsage.event(
            id: "m", sessionId: "s",
            data: message(input: 0, output: 0, reasoning: 0, cacheRead: 0, cacheWrite: 0)) == nil)
}

/// The price comes from the thing that paid it. opencode knows every provider it can reach;
/// Perch's table knows two vendors, and would call the rest free.
@Test func theCostIsTheOneOpencodePublished() throws {
    let free = try #require(OpencodeUsage.event(id: "a", sessionId: "s", data: message(cost: 0)))
    #expect(free.cost == 0)

    let paid = try #require(
        OpencodeUsage.event(
            id: "b", sessionId: "s", data: message(model: "claude-opus-5", cost: 0.42)))
    #expect(paid.cost == 0.42)
    #expect(paid.model == "claude-opus-5")
}

// MARK: - Reading the store

@Test func readsEveryAssistantMessageInTheStore() throws {
    let url = try makeOpencodeDatabase([
        ("msg_1", "ses_1", 1_000, message()),
        ("msg_2", "ses_1", 2_000, message(model: "minimax-m2.5-free")),
    ])
    defer { try? FileManager.default.removeItem(at: url) }

    let reading = try #require(try OpencodeUsage.read(databaseURL: url))
    #expect(reading.events.map(\.messageId) == ["msg_1", "msg_2"])
    #expect(reading.watermark == 2_000)
}

/// Two messages can share a millisecond, so the resume is `>=` and the boundary row is read
/// again. The index deduplicates it, which is what makes that safe.
@Test func resumingIncludesTheBoundaryRatherThanSkippingIt() throws {
    let url = try makeOpencodeDatabase([
        ("msg_1", "ses_1", 1_000, message()),
        ("msg_2", "ses_1", 2_000, message()),
        ("msg_3", "ses_1", 2_000, message()),
    ])
    defer { try? FileManager.default.removeItem(at: url) }

    let reading = try #require(try OpencodeUsage.read(databaseURL: url, since: 2_000))
    #expect(reading.events.map(\.messageId) == ["msg_2", "msg_3"])
}

@Test func aMachineWithoutOpencodeReadsNothingRatherThanFailing() throws {
    let missing = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("perch-absent-\(UUID().uuidString).db")
    #expect(try OpencodeUsage.read(databaseURL: missing) == nil)
}

// MARK: - Indexing

private func makeStore() throws -> (UsageStore, URL) {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("perch-usage-\(UUID().uuidString).sqlite")
    return (try UsageStore(path: url.path), url)
}

@Test func theIndexerResumesFromWhereTheStoreLeftOff() throws {
    let (store, storeURL) = try makeStore()
    defer { try? FileManager.default.removeItem(at: storeURL) }

    let url = try makeOpencodeDatabase([("msg_1", "ses_1", 1_000, message())])
    defer { try? FileManager.default.removeItem(at: url) }

    let indexer = UsageIndexer(store: store, roots: [], opencodeDatabase: url)
    #expect(try indexer.indexAll().eventsInserted == 1)
    // Nothing new to read.
    #expect(try indexer.indexAll().eventsInserted == 0)

    try append([("msg_2", "ses_1", 3_000, message())], to: url)
    #expect(try indexer.indexAll().eventsInserted == 1)
    #expect(try store.totals(agent: .opencode).events == 2)
}

/// The reason the agent had to become a column. opencode runs whatever model it is pointed
/// at, so a `claude-*` row of its own — which the old `model LIKE` rule would have filed
/// under the Claude tab, on top of Claude Code's own numbers.
@Test func opencodeRunningAClaudeModelStaysUnderItsOwnTab() throws {
    let (store, storeURL) = try makeStore()
    defer { try? FileManager.default.removeItem(at: storeURL) }

    let url = try makeOpencodeDatabase([
        ("msg_1", "ses_1", 1_000, message(model: "claude-opus-5", input: 100, cacheRead: 0)),
        ("msg_2", "ses_1", 1_100, message(model: "gpt-5.6-terra", input: 7, cacheRead: 0)),
    ])
    defer { try? FileManager.default.removeItem(at: url) }

    let indexer = UsageIndexer(store: store, roots: [], opencodeDatabase: url)
    try indexer.indexAll()

    #expect(try store.totals(agent: .opencode).inputTokens == 107)
    #expect(try store.totals(agent: .claude).inputTokens == 0)
    #expect(try store.totals(agent: .codex).inputTokens == 0)
    #expect(try store.agentsWithUsage() == [.opencode])
}
