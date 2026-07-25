import Foundation
import Testing

@testable import PerchKit

private func file(_ id: String, _ subject: String, _ status: String) -> Data {
    Data(
        """
        {"id":"\(id)","subject":"\(subject)","description":"…","activeForm":"doing \(id)",
         "status":"\(status)","blocks":[],"blockedBy":[]}
        """.utf8)
}

@Test func aBoardReadsWhatIsHappeningFirstAndWhatIsDoneLast() {
    let board = TaskBoard.make(from: [
        file("0", "Safe defaults", "completed"),
        file("4", "Writes plus human approval", "in_progress"),
        file("1", "Split the system prompt", "completed"),
        file("5", "Plan mode", "pending"),
        file("6", "Project registry", "pending"),
    ])

    #expect(board.tasks.map(\.id) == ["4", "5", "6", "0", "1"])
    #expect(board.inProgress == 1)
    #expect(board.open == 2)
    #expect(board.completed == 2)
    #expect(board.current?.subject == "Writes plus human approval")
}

/// Ids are strings on disk but numbers in meaning. Sorted as text, step 10 lands between
/// step 1 and step 2 and the plan reads in the wrong order.
@Test func stepTenComesAfterStepNine() {
    let board = TaskBoard.make(from: (1...11).map { file("\($0)", "step \($0)", "pending") })
    #expect(board.tasks.map(\.id) == ["1", "2", "3", "4", "5", "6", "7", "8", "9", "10", "11"])
}

/// Claude Code rewrites these files while the panel is reading them, so a truncated one
/// is normal traffic rather than an error worth losing the whole board over.
@Test func aHalfWrittenFileDropsOnlyItself() {
    let board = TaskBoard.make(from: [
        file("1", "Fine", "completed"),
        Data("{\"id\":\"2\",\"subj".utf8),
        file("3", "Also fine", "pending"),
    ])

    #expect(board.tasks.map(\.id) == ["3", "1"])
}

/// A status this version has never seen is still a task on the list.
@Test func anUnknownStatusIsKeptRatherThanDropped() {
    let board = TaskBoard.make(from: [file("1", "Something new", "deferred")])

    #expect(board.tasks.count == 1)
    #expect(board.tasks[0].status == .pending)
}

@Test func aSessionThatNeverUsedTasksHasAnEmptyBoard() {
    let board = TaskReader.board(
        for: "no-such-session", root: URL(fileURLWithPath: "/tmp/perch-tests-absent"))
    #expect(board.isEmpty)
    #expect(board.current == nil)
}

/// The end-to-end read, against a directory laid out the way Claude Code lays one out —
/// including the `.lock` and `.highwatermark` that sit beside the tasks.
@Test func theReaderSkipsWhatIsNotATask() throws {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("perch-tasks-\(UUID().uuidString)", isDirectory: true)
    let session = "abc-123"
    let directory = TaskReader.directory(for: session, root: root)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    try file("1", "Done", "completed").write(to: directory.appendingPathComponent("1.json"))
    try file("2", "Now", "in_progress").write(to: directory.appendingPathComponent("2.json"))
    try Data().write(to: directory.appendingPathComponent(".lock"))
    try Data("7".utf8).write(to: directory.appendingPathComponent(".highwatermark"))

    let board = TaskReader.board(for: session, root: root)
    #expect(board.tasks.map(\.id) == ["2", "1"])
    #expect(board.completed == 1)
}
