import Foundation
import Testing

@testable import PerchKit

/// Lines in the shapes a real rollout uses. Taken from a Codex Desktop session that was
/// running while this was written, trimmed to the fields that are read.
private enum Line {
    static func meta(
        id: String = "019fbcf4-e1c5-7330-a3f0-1cd11bf960fa",
        cwd: String = "/Users/kevin/lab/iautos-mobile",
        originator: String = "Codex Desktop"
    ) -> String {
        // `base_instructions` is why the header is read with a byte bound: on a desktop
        // session it carries the whole system prompt.
        """
        {"timestamp":"2026-08-01T10:55:22.221Z","type":"session_meta","payload":\
        {"session_id":"\(id)","cwd":"\(cwd)","originator":"\(originator)",\
        "cli_version":"0.146.0-alpha.9.2","source":"vscode",\
        "base_instructions":{"text":"\(String(repeating: "x", count: 4096))"}}}
        """
    }

    static let reasoning =
        #"{"timestamp":"2026-08-01T11:02:27.569Z","type":"response_item","payload":{"type":"reasoning"}}"#

    static func toolCall(name: String = "exec", input: String = "ls -la") -> String {
        """
        {"timestamp":"2026-08-01T11:02:34.040Z","type":"response_item","payload":\
        {"type":"custom_tool_call","name":"\(name)","input":"\(input)","status":"in_progress"}}
        """
    }

    static let toolOutput =
        #"{"timestamp":"2026-08-01T11:02:34.064Z","type":"response_item","payload":{"type":"custom_tool_call_output"}}"#

    static func agentMessage(_ text: String) -> String {
        """
        {"timestamp":"2026-08-01T11:02:30.922Z","type":"event_msg","payload":\
        {"type":"agent_message","message":"\(text)","phase":"final"}}
        """
    }

    static let tokenCount =
        #"{"timestamp":"2026-08-01T11:02:34.064Z","type":"event_msg","payload":{"type":"token_count"}}"#
}

/// A rollout tree laid out the way Codex files them: `sessions/YYYY/MM/DD/rollout-…-<uuid>.jsonl`.
private struct Fixture {
    let root: URL
    let index: URL

    init() throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("perch-codex-\(UUID().uuidString)")
        root = base.appendingPathComponent("sessions", isDirectory: true)
        index = base.appendingPathComponent("session_index.jsonl")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func destroy() { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

    @discardableResult
    func rollout(
        id: String, day: Date, lines: [String], modified: Date? = nil
    ) throws -> URL {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day], from: day)
        let directory =
            root
            .appendingPathComponent(String(format: "%04d", parts.year!), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", parts.month!), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", parts.day!), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let url = directory.appendingPathComponent("rollout-2026-08-01T12-53-13-\(id).jsonl")
        try (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        if let modified {
            try FileManager.default.setAttributes(
                [.modificationDate: modified], ofItemAtPath: url.path)
        }
        return url
    }

    func names(_ lines: [String]) throws {
        try (lines.joined(separator: "\n") + "\n")
            .write(to: index, atomically: true, encoding: .utf8)
    }
}

private let sessionA = "019fbcf4-e1c5-7330-a3f0-1cd11bf960fa"
private let sessionB = "019fbcba-5dda-7e60-af11-dddc12a2ae00"

@Suite("Codex sessions")
struct CodexSessionsTests {

    /// The whole point: a desktop session that never sends a hook still becomes a card.
    @Test func aDesktopSessionBecomesACardWithoutAnyHook() throws {
        let fixture = try Fixture()
        defer { fixture.destroy() }

        let now = Date()
        try fixture.rollout(
            id: sessionA, day: now,
            lines: [Line.meta(), Line.reasoning, Line.toolCall(input: "npm test")],
            modified: now.addingTimeInterval(-5))
        try fixture.names([
            #"{"id":"\#(sessionA)","thread_name":"Revoir tabs et header mobile"}"#
        ])

        let live = CodexSessions.live(
            root: fixture.root, index: fixture.index, now: now, activeWithin: 1800)

        #expect(live.count == 1)
        let session = try #require(live.first)
        #expect(session.id == sessionA)
        #expect(session.cwd == "/Users/kevin/lab/iautos-mobile")
        #expect(session.originator == "Codex Desktop")
        #expect(session.title == "Revoir tabs et header mobile")
        #expect(session.detail == "exec: npm test")
        #expect(session.isRunningTool)
        #expect(session.isWorking(now: now, within: 45))
    }

    /// A tool whose output has arrived is finished, and a card still drawing it as running
    /// is a card claiming work that is over.
    @Test func aToolWithItsOutputIsNoLongerRunning() throws {
        let fixture = try Fixture()
        defer { fixture.destroy() }
        let now = Date()
        try fixture.rollout(
            id: sessionA, day: now,
            lines: [Line.meta(), Line.toolCall(), Line.toolOutput, Line.tokenCount],
            modified: now)

        let live = CodexSessions.live(
            root: fixture.root, index: fixture.index, now: now, activeWithin: 1800)
        #expect(live.first?.isRunningTool == false)
        // Still the tool, because it is what the session last did — only its state moved.
        #expect(live.first?.detail == "exec: ls -la")
    }

    /// Silence is the only end-of-turn signal a rollout has.
    @Test func aSessionThatStoppedWritingIsNoLongerWorking() throws {
        let fixture = try Fixture()
        defer { fixture.destroy() }
        let now = Date()
        try fixture.rollout(
            id: sessionA, day: now, lines: [Line.meta(), Line.agentMessage("Done.")],
            modified: now.addingTimeInterval(-300))

        let session = try #require(
            CodexSessions.live(
                root: fixture.root, index: fixture.index, now: now, activeWithin: 1800
            ).first)
        #expect(!session.isWorking(now: now, within: 45))
        #expect(session.detail == "Done.")
    }

    /// A rollout nobody has touched for longer than the timeout is a session that is gone.
    @Test func aStaleRolloutIsNotASession() throws {
        let fixture = try Fixture()
        defer { fixture.destroy() }
        let now = Date()
        try fixture.rollout(
            id: sessionA, day: now, lines: [Line.meta()],
            modified: now.addingTimeInterval(-3600))

        #expect(
            CodexSessions.live(
                root: fixture.root, index: fixture.index, now: now, activeWithin: 1800
            ).isEmpty)
    }

    /// Rollouts are filed by the day they *started*, so a session open since yesterday is
    /// still writing into yesterday's directory.
    @Test func aSessionOpenedYesterdayIsStillFound() throws {
        let fixture = try Fixture()
        defer { fixture.destroy() }
        let now = Date()
        let yesterday = now.addingTimeInterval(-86_400)
        try fixture.rollout(
            id: sessionB, day: yesterday, lines: [Line.meta(id: sessionB)],
            modified: now.addingTimeInterval(-10))

        let live = CodexSessions.live(
            root: fixture.root, index: fixture.index, now: now, activeWithin: 1800)
        #expect(live.map(\.id) == [sessionB])
    }

    /// The newest name wins: Codex renames a thread as it learns what it is about, and
    /// appends rather than rewrites.
    @Test func theLastThreadNameForAnIdIsTheOneUsed() throws {
        let fixture = try Fixture()
        defer { fixture.destroy() }
        try fixture.names([
            #"{"id":"\#(sessionA)","thread_name":"Untitled"}"#,
            #"{"id":"\#(sessionA)","thread_name":"Revoir tabs et header mobile"}"#,
        ])
        #expect(
            CodexSessions.threadNames(index: fixture.index)[sessionA]
                == "Revoir tabs et header mobile")
    }

    /// The desktop app prefixes ambient turns with a block nobody typed. Showing it back
    /// would put plumbing where the question belongs — the same reason the Claude side
    /// strips `<system-reminder>`.
    @Test func ambientScaffoldingIsNotAnActivityLine() {
        let text = """
            <in-app-browser-context source="ambient-ui-state">
            This block is automatically supplied ambient UI state.
            </in-app-browser-context>
            Revoir les tabs
            """
        #expect(CodexSessions.condense(text) == "Revoir les tabs")
    }

    /// Sessions come out newest first, which is the order the strip draws them in.
    @Test func theNewestSessionComesFirst() throws {
        let fixture = try Fixture()
        defer { fixture.destroy() }
        let now = Date()
        try fixture.rollout(
            id: sessionA, day: now, lines: [Line.meta(id: sessionA)],
            modified: now.addingTimeInterval(-600))
        try fixture.rollout(
            id: sessionB, day: now, lines: [Line.meta(id: sessionB)],
            modified: now.addingTimeInterval(-5))

        let live = CodexSessions.live(
            root: fixture.root, index: fixture.index, now: now, activeWithin: 1800)
        #expect(live.map(\.id) == [sessionB, sessionA])
    }

    /// A header too corrupt to parse is still a session: the id is in the filename, and a
    /// card with no project name beats no card at all.
    @Test func aSessionSurvivesAnUnreadableHeader() throws {
        let fixture = try Fixture()
        defer { fixture.destroy() }
        let now = Date()
        try fixture.rollout(
            id: sessionA, day: now, lines: ["{not json at all", Line.reasoning], modified: now)

        let session = try #require(
            CodexSessions.live(
                root: fixture.root, index: fixture.index, now: now, activeWithin: 1800
            ).first)
        #expect(session.id == sessionA)
        #expect(session.cwd == nil)
    }
}

@Suite("Codex tool summaries")
struct CodexToolSummaryTests {

    /// The desktop app writes a fragment of JavaScript around the arguments. What a card
    /// wants is the command inside it.
    @Test func theCommandIsPulledOutOfTheJavaScriptWrapper() {
        let input = #"const r = await tools.exec_command({"cmd":"npm test -- --watch=false"})"#
        #expect(CodexSessions.toolSummary(name: "exec", input: input) == "exec: npm test -- --watch=false")
    }

    /// Real inputs carry newlines inside the command, because a shell call can be a script.
    @Test func aMultiLineCommandBecomesOneLine() {
        let input = "const r = await tools.exec_command({\"cmd\":\"sed -n '1,180p' A.tsx\nsed -n '1,120p' B.tsx\"})"
        #expect(
            CodexSessions.toolSummary(name: "exec", input: input)
                == "exec: sed -n '1,180p' A.tsx sed -n '1,120p' B.tsx")
    }

    /// Nothing in there is about the work, so the name is the better answer — this is the
    /// call that used to put `wait: {"cell_id":"37","yield_time_ms":20000}` on a card.
    @Test func argumentsThatSayNothingLeaveJustTheName() {
        let input = #"{"cell_id":"37","yield_time_ms":20000,"max_tokens":20000}"#
        #expect(CodexSessions.toolSummary(name: "wait", input: input) == "wait")
    }

    @Test func aToolWithNoArgumentsIsItsName() {
        #expect(CodexSessions.toolSummary(name: "read_file", input: "") == "read_file")
    }
}
