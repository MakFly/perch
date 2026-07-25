import Observation
import PerchKit

/// The task lists of every session Perch is watching.
///
/// Re-read whenever a session sends a hook event, which is exactly when its plan can have
/// moved: the task tool writes its files during the turn, and every write is bracketed by
/// tool hooks Perch already receives. Nothing polls.
///
/// The directory's own timestamp is not a usable change signal — the task tool rewrites an
/// existing file when a step changes status, which moves the file's date and not the
/// directory's — so the board is rebuilt and then compared. A dozen small JSON files cost
/// less to read than the redraw that publishing an unchanged board would trigger.
@MainActor
@Observable
final class TaskStore {
    private var boards: [String: TaskBoard] = [:]

    func board(for sessionId: String?) -> TaskBoard {
        sessionId.flatMap { boards[$0] } ?? .empty
    }

    func refresh(_ sessionId: String?) {
        guard let sessionId, !sessionId.isEmpty else { return }
        let next = TaskReader.board(for: sessionId)
        guard next != boards[sessionId] else { return }
        boards[sessionId] = next
    }

    /// Reads every session at once.
    ///
    /// Refreshing on hook events alone leaves a hole: a session that was already running
    /// when Perch restarted, and has been quiet since, has no board until it next moves —
    /// so the panel would open on a plan that exists on disk and is not shown. Opening the
    /// panel is a deliberate act and a rare one, which makes it the right moment to pay
    /// for a handful of directory reads.
    func refreshAll(_ sessionIds: [String]) {
        for id in sessionIds { refresh(id) }
    }

    /// Sessions that ended keep their files on disk long after the panel stops showing
    /// them, so the cache is trimmed to what is still on screen.
    func forget(keeping live: Set<String>) {
        boards = boards.filter { live.contains($0.key) }
    }
}
