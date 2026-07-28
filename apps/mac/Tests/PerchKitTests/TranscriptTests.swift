import Foundation
import Testing

@testable import PerchKit

/// Lines in the shape Claude Code actually writes them, which is the whole risk here: the
/// file is someone else's format and every one of these cases came off a real transcript.
private func line(_ object: [String: Any]) -> Data {
    try! JSONSerialization.data(withJSONObject: object)
}

private func user(_ content: Any, extra: [String: Any] = [:]) -> Data {
    line(["type": "user", "message": ["role": "user", "content": content]].merging(extra) { _, b in b })
}

private func assistant(_ blocks: [[String: Any]], extra: [String: Any] = [:]) -> Data {
    line(
        ["type": "assistant", "message": ["role": "assistant", "content": blocks]]
            .merging(extra) { _, b in b })
}

@Suite("Transcript")
struct TranscriptTests {

    @Test("the last turn is the last prompt and everything said after it")
    func lastTurn() {
        let turn = Transcript.turn(in: [
            user("an older question"),
            assistant([["type": "text", "text": "an older answer"]]),
            user("what does this do?"),
            assistant([["type": "text", "text": "It reads the file."]]),
        ])

        #expect(turn?.prompt == "what does this do?")
        #expect(turn?.reply == "It reads the file.")
    }

    @Test("a tool result is not a prompt")
    func toolResultsAreNotPrompts() {
        // Results come back as `user` lines. Taking one for a prompt puts a diff where the
        // question belongs — which is exactly what it did before this test existed.
        let turn = Transcript.turn(in: [
            user("run the tests"),
            assistant([["type": "tool_use", "name": "Bash", "id": "1"]]),
            user([["type": "tool_result", "tool_use_id": "1", "content": "272 passed"]]),
            assistant([["type": "text", "text": "All green."]]),
        ])

        #expect(turn?.prompt == "run the tests")
        #expect(turn?.reply == "All green.")
    }

    @Test("prose either side of a tool call is two paragraphs, not one sentence")
    func repliesAcrossToolCallsAreJoined() {
        let turn = Transcript.turn(in: [
            user("fix it"),
            assistant([["type": "text", "text": "Looking."]]),
            assistant([["type": "tool_use", "name": "Edit", "id": "1"]]),
            assistant([["type": "text", "text": "Fixed."]]),
        ])

        #expect(turn?.reply == "Looking.\n\nFixed.")
    }

    @Test("thinking is not addressed to anyone, and is left out")
    func thinkingIsExcluded() {
        let turn = Transcript.turn(in: [
            user("why?"),
            assistant([
                ["type": "thinking", "thinking": "the user probably means the second one"],
                ["type": "text", "text": "Because the cache is keyed on the request id."],
            ]),
        ])

        #expect(turn?.reply == "Because the cache is keyed on the request id.")
    }

    @Test("content arrives as a bare string too, and short prompts are exactly those")
    func stringContent() {
        let turn = Transcript.turn(in: [
            user("go"),
            assistant([["type": "text", "text": "Starting."]]),
        ])

        #expect(turn?.prompt == "go")
    }

    @Test("a subagent's conversation is not this session's")
    func sidechainsAreExcluded() {
        // Fan-out `Task` calls write into the same file under `isSidechain`. Their prompts
        // would otherwise replace the one on screen mid-turn.
        let turn = Transcript.turn(in: [
            user("summarise the repo"),
            assistant([["type": "text", "text": "On it."]]),
            user("search for TODOs", extra: ["isSidechain": true]),
            assistant([["type": "text", "text": "found 4"]], extra: ["isSidechain": true]),
        ])

        #expect(turn?.prompt == "summarise the repo")
        #expect(turn?.reply == "On it.")
    }

    @Test("the scaffolding Claude Code injects is not something the user typed")
    func injectedTagsAreStripped() {
        let turn = Transcript.turn(in: [
            user("<command-name>/goal</command-name>\nreach parity"),
            assistant([["type": "text", "text": "Noted."]]),
        ])

        #expect(turn?.prompt == "reach parity")
    }

    @Test("a message that is only scaffolding is not a prompt at all")
    func scaffoldingOnlyIsNotAPrompt() {
        // A finished subagent posts one of these back into the conversation. The card read
        // it as the question the user had asked, and printed a tool-use id.
        let turn = Transcript.turn(in: [
            user("what changed?"),
            assistant([["type": "text", "text": "Two files."]]),
            user("<task-notification><task-id>aa4f8891</task-id></task-notification>"),
            assistant([["type": "text", "text": "The subagent finished."]]),
        ])

        #expect(turn?.prompt == "what changed?")
        #expect(turn?.reply == "Two files.\n\nThe subagent finished.")
    }

    @Test("a window that opens mid-turn still shows the reply it can see")
    func replyWithoutItsPrompt() {
        // Reading the tail of a megabyte file lands mid-turn; the prompt is then simply
        // not in the window. The card has the hook's own copy to fall back on.
        let turn = Transcript.turn(in: [
            assistant([["type": "text", "text": "…and that is why it double-counts."]])
        ])

        #expect(turn?.prompt == nil)
        #expect(turn?.reply == "…and that is why it double-counts.")
    }

    @Test("nothing readable is nothing, not an empty turn")
    func emptyIsNil() {
        #expect(Transcript.turn(in: []) == nil)
        #expect(Transcript.turn(in: [assistant([["type": "tool_use", "name": "Bash"]])]) == nil)
    }

    @Test("reads from the end of a real file")
    func readsFromDisk() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("perch-transcript-\(UUID().uuidString).jsonl")
        let lines = [
            user("first"), assistant([["type": "text", "text": "one"]]),
            user("second"), assistant([["type": "text", "text": "two"]]),
        ]
        var file = Data()
        for line in lines {
            file.append(line)
            file.append(0x0A)
        }
        try file.write(to: path)
        defer { try? FileManager.default.removeItem(at: path) }

        let turn = Transcript.lastTurn(path: path.path)
        #expect(turn?.prompt == "second")
        #expect(turn?.reply == "two")
    }
}
