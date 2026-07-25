import Foundation

/// One item of the plan an agent is working through.
///
/// Claude Code writes these as one JSON file per task under
/// `~/.claude/tasks/<session id>/<n>.json`, and rewrites the file whose status changed.
/// Nothing has to be intercepted to read them: the session id arrives on every hook
/// payload, and it is the name of the directory.
public struct AgentTask: Sendable, Equatable, Identifiable {
    public enum Status: String, Sendable, Equatable, Codable {
        case pending
        case inProgress = "in_progress"
        case completed
    }

    public var id: String
    public var subject: String
    public var status: Status
    /// The present-tense phrasing Claude Code uses while the task is the current one
    /// ("Building the socle chat"). Absent on older files.
    public var activeForm: String?

    public init(id: String, subject: String, status: Status, activeForm: String? = nil) {
        self.id = id
        self.subject = subject
        self.status = status
        self.activeForm = activeForm
    }
}

extension AgentTask: Decodable {
    enum CodingKeys: String, CodingKey {
        case id, subject, status, activeForm
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        subject = try container.decode(String.self, forKey: .subject)
        activeForm = try container.decodeIfPresent(String.self, forKey: .activeForm)
        // A status Perch has not seen yet must not throw the task away: an unknown state
        // is still a task on the list, and reading it as pending is the honest guess.
        let raw = try container.decodeIfPresent(String.self, forKey: .status) ?? ""
        status = Status(rawValue: raw) ?? .pending
    }
}

/// A session's task list, ordered the way it is read rather than the way it is stored.
public struct TaskBoard: Sendable, Equatable {
    /// Display order: what is happening now, then what is next, then what is done.
    public var tasks: [AgentTask]
    public var completed: Int
    public var inProgress: Int
    public var open: Int

    public var isEmpty: Bool { tasks.isEmpty }
    /// The task the agent says it is on, which is the one line worth showing collapsed.
    public var current: AgentTask? { tasks.first { $0.status == .inProgress } }

    public static let empty = TaskBoard(tasks: [], completed: 0, inProgress: 0, open: 0)

    /// Builds a board from the raw contents of a task directory.
    ///
    /// Pure on purpose — the directory read is the caller's problem, so the ordering and
    /// the counts can be tested without a filesystem.
    public static func make(from files: [Data]) -> TaskBoard {
        let decoder = JSONDecoder()
        // A half-written file is normal: Claude Code rewrites these while we watch. It is
        // dropped for this pass and picked up on the next one, rather than failing the
        // whole board.
        let tasks = files.compactMap { try? decoder.decode(AgentTask.self, from: $0) }

        // Ids are "1", "2" … "10", so they have to be compared as numbers. Sorted as
        // strings, "10" lands between "1" and "2" and the plan reads out of order.
        func before(_ a: AgentTask, _ b: AgentTask) -> Bool {
            switch (Int(a.id), Int(b.id)) {
            case let (x?, y?): return x < y
            default: return a.id < b.id
            }
        }

        func inStatus(_ status: AgentTask.Status) -> [AgentTask] {
            tasks.filter { $0.status == status }.sorted(by: before)
        }

        let running = inStatus(.inProgress)
        let pending = inStatus(.pending)
        let done = inStatus(.completed)

        return TaskBoard(
            tasks: running + pending + done,
            completed: done.count,
            inProgress: running.count,
            open: pending.count)
    }
}

/// Where a session's tasks live, and how to read them.
public enum TaskReader: Sendable {
    public static func defaultRoot() -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/tasks", isDirectory: true)
    }

    public static func directory(for sessionId: String, root: URL? = nil) -> URL {
        (root ?? defaultRoot()).appendingPathComponent(sessionId, isDirectory: true)
    }

    /// Reads and orders one session's board. Returns empty for a session that never used
    /// the task tool, which is most of them.
    public static func board(for sessionId: String, root: URL? = nil) -> TaskBoard {
        let directory = directory(for: sessionId, root: root)
        guard
            let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        else { return .empty }

        // `.lock` and `.highwatermark` live in the same directory and are not tasks.
        let files = names.filter { $0.hasSuffix(".json") }.compactMap {
            try? Data(contentsOf: directory.appendingPathComponent($0))
        }
        return .make(from: files)
    }
}
