import Foundation
import Observation
import PerchKit

/// Holds permission requests until the user answers them.
///
/// Every pending request is a blocked Claude Code session, so the invariant that matters
/// is that each one is always resolved — by a click, or by the timeout below.
@MainActor
@Observable
final class PermissionBroker {
    /// Oldest first: whoever has been blocked longest gets answered first.
    private(set) var queue: [PendingPermission] = []

    /// Slightly under the hook's own timeout, so Perch decides rather than letting the
    /// hook give up — otherwise the UI would still show a request nobody is waiting on.
    ///
    /// The hook waits a day: a request left overnight should still be answerable in the
    /// morning rather than silently expired at minute five. Quitting Perch, or killing it,
    /// releases every blocked session immediately, so this is a backstop and not the
    /// mechanism that keeps sessions from hanging.
    private let expiry: Duration = .seconds(86_100)

    var current: PendingPermission? { queue.first }
    var waitingCount: Int { queue.count }

    /// Whether this exact request is already on screen — which is how a second hook firing
    /// for the same event is told apart from a genuinely new one.
    func hasPending(matching request: PerchRequest) -> Bool {
        guard let key = request.duplicateKey else { return false }
        return queue.contains { $0.duplicateKey == key && !$0.isResolved }
    }

    /// Called from the event server. Suspends until the user decides.
    ///
    /// A request that is already on screen is not queued a second time: hooks installed in
    /// two scopes both fire for one event, and both block the same session. They wait
    /// together on one card and are answered together, because there is only one decision
    /// being made.
    func request(_ request: PerchRequest) async -> PerchResponse {
        await withCheckedContinuation { continuation in
            if let key = request.duplicateKey,
                let twin = queue.first(where: { $0.duplicateKey == key && !$0.isResolved })
            {
                twin.attach(continuation)
                return
            }

            let pending = PendingPermission(request: request, continuation: continuation)
            queue.append(pending)
            scheduleExpiry(for: pending)
        }
    }

    func resolve(
        _ pending: PendingPermission,
        with decision: PermissionDecision,
        reason: String? = nil,
        rule: RememberedRule? = nil,
        updatedInput: JSONValue? = nil,
        planMode: PlanMode? = nil
    ) {
        pending.resolve(
            decision, reason: reason, rule: rule, updatedInput: updatedInput,
            planMode: planMode)
        queue.removeAll { $0.id == pending.id }
    }

    func resolveCurrent(with decision: PermissionDecision) {
        guard let current else { return }
        resolve(current, with: decision)
    }

    /// Falls back to `ask`, which hands the decision to Claude Code's own prompt. The
    /// session then behaves as if Perch were not installed instead of hanging.
    private func scheduleExpiry(for pending: PendingPermission) {
        let expiry = expiry
        Task { [weak self] in
            try? await Task.sleep(for: expiry)
            guard let self, !pending.isResolved else { return }
            pending.resolve(.ask, reason: "Perch timed out waiting for a decision")
            self.queue.removeAll { $0.id == pending.id }
        }
    }

    /// Answers everything waiting the same way.
    ///
    /// Only offered when several are queued, and only for the two answers that are safe to
    /// give blind: allow, and deny. "Always" is deliberately not here — writing a rule for
    /// a request you did not read is how a permission system stops meaning anything.
    func resolveAll(with decision: PermissionDecision) {
        let waiting = queue
        queue.removeAll()
        for pending in waiting {
            pending.resolve(decision, reason: "Answered with the rest of the queue")
        }
    }

    /// On quit, unblock everything rather than leaving sessions stuck.
    func resolveAllPending() {
        for pending in queue {
            pending.resolve(.ask, reason: "Perch quit")
        }
        queue.removeAll()
    }
}
