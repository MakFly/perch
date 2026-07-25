import Foundation
import Testing

@testable import PerchKit

private func transcript(_ lines: [String]) -> String {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("perch-title-\(UUID().uuidString).jsonl")
    try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    return url.path
}

/// Claude Code names its own sessions. Perch reads that rather than spending a model call
/// inventing a second, different name for the same work.
@Test func readsTheTitleClaudeCodeAlreadyWrote() {
    let path = transcript([
        #"{"type":"user","message":{}}"#,
        #"{"type":"ai-title","aiTitle":"Fix dark mode borders","sessionId":"s1"}"#,
        #"{"type":"assistant","message":{}}"#,
    ])
    #expect(SessionTitle.read(transcriptPath: path) == "Fix dark mode borders")
    try? FileManager.default.removeItem(atPath: path)
}

/// The line repeats as the title is refined, so the last one is the current one.
@Test func theLatestTitleWins() {
    let path = transcript([
        #"{"type":"ai-title","aiTitle":"First guess","sessionId":"s1"}"#,
        #"{"type":"ai-title","aiTitle":"Better name","sessionId":"s1"}"#,
    ])
    #expect(SessionTitle.read(transcriptPath: path) == "Better name")
    try? FileManager.default.removeItem(atPath: path)
}

@Test func aTranscriptWithNoTitleYieldsNothing() {
    let path = transcript([#"{"type":"user","message":{}}"#])
    #expect(SessionTitle.read(transcriptPath: path) == nil)
    #expect(SessionTitle.read(transcriptPath: "/nonexistent.jsonl") == nil)
    try? FileManager.default.removeItem(atPath: path)
}

/// Reading only the tail of a multi-megabyte file means starting mid-line; that partial
/// line has to be dropped rather than parsed into something wrong.
@Test func aPartialFirstLineIsDiscarded() {
    let padding = String(repeating: #"{"type":"assistant","filler":"x"}"#, count: 1)
    var lines = (0..<200).map { _ in padding }
    lines.append(#"{"type":"ai-title","aiTitle":"Real title","sessionId":"s1"}"#)
    let path = transcript(lines)

    #expect(SessionTitle.read(transcriptPath: path, maximumBytes: 400) == "Real title")
    try? FileManager.default.removeItem(atPath: path)
}

/// Titles arrive both as prose and as slugs — both are real, and the card reads better
/// with one shape.
@Test func slugTitlesAreMadeReadable() {
    #expect(SessionTitle.clean("limit-active-sessions-10") == "Limit active sessions 10")
    #expect(SessionTitle.clean("Fix dark mode borders") == "Fix dark mode borders")
    // A hyphen inside a sentence is punctuation, not a slug.
    #expect(SessionTitle.clean("Fix the dark-mode borders") == "Fix the dark-mode borders")
    #expect(SessionTitle.clean("  spaced  ") == "spaced")
}

@Test func theCardPrefersTheRealNameOverThePrompt() {
    var tracker = SessionTracker()
    let epoch = Date(timeIntervalSince1970: 1_700_000_000)
    tracker.record(
        id: "s1", kind: "UserPromptSubmit", cwd: "/lab/perch",
        prompt: "please fix the borders in dark mode when the sidebar is collapsed",
        at: epoch)
    #expect(tracker.sessions["s1"]?.title.hasPrefix("please fix") == true)

    tracker.record(id: "s1", kind: "PreToolUse", aiTitle: "Fix dark mode borders", at: epoch)
    #expect(tracker.sessions["s1"]?.title == "Fix dark mode borders")
}
