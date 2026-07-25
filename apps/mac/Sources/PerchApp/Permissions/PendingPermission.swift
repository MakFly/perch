import Foundation
import PerchKit

/// A tool call waiting for the user to decide, and the continuations that unblock the
/// hooks — and therefore the Claude Code session — once they do.
///
/// Continuations, plural: the same event reaches Perch once per hook entry that matched
/// it, so a settings file that installs Perch twice blocks the session twice over one
/// decision. Those copies are held here rather than queued as their own cards, because
/// answering a request you have already answered is not a question worth asking.
@MainActor
final class PendingPermission: Identifiable {
    let id = UUID()
    let request: PerchRequest
    let arrivedAt: Date
    /// Recognises the copies. Nil when the payload gave nothing to key on, in which case
    /// nothing is ever attached and this behaves exactly as it did before.
    let duplicateKey: String?
    private var continuations: [CheckedContinuation<PerchResponse, Never>]

    init(
        request: PerchRequest,
        arrivedAt: Date = .now,
        continuation: CheckedContinuation<PerchResponse, Never>
    ) {
        self.request = request
        self.arrivedAt = arrivedAt
        self.duplicateKey = request.duplicateKey
        self.continuations = [continuation]
    }

    /// Adds another hook waiting on this same decision.
    func attach(_ continuation: CheckedContinuation<PerchResponse, Never>) {
        continuations.append(continuation)
    }

    var tool: String { request.payload.toolName ?? "Tool" }
    var cwd: String? { request.payload.cwd }
    var sessionId: String? { request.payload.sessionId }

    var projectName: String? {
        cwd.map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    /// What the tool is about to do, in one line.
    var detail: String { ActivityEvent.summarize(request) }

    /// Resolves every hook waiting on this decision. Safe to call twice — the second call
    /// is ignored, which matters because a timeout and a click can race.
    func resolve(
        _ decision: PermissionDecision,
        reason: String? = nil,
        rule: RememberedRule? = nil,
        updatedInput: JSONValue? = nil
    ) {
        guard !continuations.isEmpty else { return }
        let waiting = continuations
        continuations = []
        let response = PerchResponse(
            decision: decision, reason: reason, rule: rule, updatedInput: updatedInput)
        for continuation in waiting { continuation.resume(returning: response) }
    }

    /// What kind of card this request deserves: a plain permission, a question to answer,
    /// or a plan to approve.
    var kind: RequestKind { RequestKind.of(request) }

    var isResolved: Bool { continuations.isEmpty }
}
