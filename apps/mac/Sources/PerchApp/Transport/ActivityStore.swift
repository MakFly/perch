import Foundation
import Observation
import PerchKit

/// Live view of what Claude Code is doing, fed by the hooks.
@MainActor
@Observable
final class ActivityStore {
    /// Most recent first. Bounded — the notch shows a handful and nothing reads further
    /// back, so there is no reason to grow without limit.
    private(set) var events: [ActivityEvent] = []
    /// Drives the idle activity line: brief pulse whenever anything happens.
    private(set) var lastEventAt: Date?
    /// Distinguishes "nothing is running" from "nothing is wired up". Counts sessions ever
    /// seen, not sessions alive, because a session that ended still proves the hooks work.
    private(set) var sessionsEverSeen = 0
    let startedAt = Date.now

    private let maximumEvents = 200
    // Observed, not ignored: the session cards redraw when this changes.
    private var tracker = SessionTracker()

    init() {
        tracker.timeout = preferences.idleTimeout
    }

    /// What is allowed into the panel at all.
    private(set) var admission = AdmissionPolicy.load()
    /// Blocked launcher apps and the idle timeout both live here.
    var preferences = Preferences.load() {
        didSet { tracker.timeout = preferences.idleTimeout }
    }
    /// Once a session is silenced it stays silenced: the prompt that identified it as
    /// background noise only arrives once, and every later event lacks it.
    private var silenced: Set<String> = []

    var sessions: [String: SessionSnapshot] { tracker.sessions }

    /// Re-read on demand rather than watched: it is only ever needed when the panel is
    /// empty, and a file watcher on someone's settings would be a lot of machinery for a
    /// question asked once a session.
    var health: HookHealth {
        HookWatcher.check(sessionsSeen: sessionsEverSeen, runningSince: startedAt)
    }

    /// Applies what the watcher read. Sessions that have since ended are ignored rather
    /// than resurrected — the read started while they were alive.
    func applyTurns(_ turns: [String: TranscriptTurn]) {
        for (id, turn) in turns { tracker.setTurn(turn, for: id) }
    }

    /// Which transcripts are worth re-reading right now: the live ones that have a path.
    var transcriptPaths: [String: String] {
        tracker.sessions.compactMapValues(\.transcriptPath)
    }

    func updateAdmission(_ policy: AdmissionPolicy) {
        admission = policy
        policy.save()
        // Re-evaluate what is already on screen, so turning a rule on takes effect now
        // rather than at the next session.
        for (id, session) in tracker.sessions
        where admission.isSilenced(directory: session.cwd, prompt: session.prompt) {
            silenced.insert(id)
            tracker.drop(id: id)
        }
    }

    /// Events that move session state but do not deserve a row of their own.
    private static let silentKinds: Set<String> = [
        "SessionStart", "SessionEnd", "SubagentStart", "SubagentStop", "PreCompact",
        "StopFailure",
    ]

    func record(_ request: PerchRequest) {
        let event = ActivityEvent(request: request)

        if let id = event.sessionId, isSilenced(id: id, request: request, event: event) {
            return
        }

        switch event.kind {
        case let kind where Self.silentKinds.contains(kind):
            break
        case "PostToolUse", "PostToolUseFailure", "PermissionDenied":
            complete(event, failed: event.kind != "PostToolUse")
        default:
            append(event)
        }

        if let id = event.sessionId {
            if tracker.sessions[id] == nil { sessionsEverSeen += 1 }
            tracker.record(
                id: id,
                kind: event.kind,
                cwd: event.cwd,
                detail: event.detail,
                prompt: request.payload.prompt,
                client: request.client,
                agent: request.agent,
                // Read from the transcript the payload points at — Claude Code names its
                // own sessions, so there is nothing here for Perch to invent.
                aiTitle: request.payload.transcriptPath.flatMap {
                    SessionTitle.read(transcriptPath: $0)
                },
                // Recorded, not read: the reading is what `TranscriptWatcher` does, off
                // this path, because this one has a blocked CLI waiting at the end of it.
                transcriptPath: request.payload.transcriptPath,
                permissionMode: request.payload.permissionMode,
                // What is waiting, and what it is waiting for: a command wants a decision,
                // a question wants an answer, a notification may mean neither.
                tool: request.payload.toolName,
                message: request.payload.message,
                subagentLabel: request.subagentLabel,
                at: event.date)
        }
    }

    /// A session identified as background noise is dropped whole — including anything it
    /// already put on screen before the prompt that gave it away arrived.
    private func isSilenced(id: String, request: PerchRequest, event: ActivityEvent) -> Bool {
        if silenced.contains(id) { return true }

        let prompt = request.payload.prompt ?? tracker.sessions[id]?.prompt
        let blockedLauncher = preferences.blocks(launcher: request.client?.launcher)
        guard blockedLauncher
            || admission.isSilenced(
                directory: event.cwd ?? tracker.sessions[id]?.cwd, prompt: prompt)
        else { return false }

        silenced.insert(id)
        tracker.drop(id: id)
        events.removeAll { $0.sessionId == id }
        return true
    }

    private func append(_ event: ActivityEvent) {
        events.insert(event, at: 0)
        if events.count > maximumEvents { events.removeLast(events.count - maximumEvents) }
        lastEventAt = event.date
    }

    /// Marks the matching in-flight row as finished. Falls back to appending when the
    /// `PreToolUse` hook never arrived — a tool that was auto-approved before Perch
    /// started, for instance.
    private func complete(_ event: ActivityEvent, failed: Bool) {
        guard let index = events.firstIndex(where: { $0.status == .running && $0.matches(event) })
        else {
            var standalone = event
            standalone.status = failed ? .failed : .done
            append(standalone)
            return
        }
        events[index].status = failed ? .failed : .done
        lastEventAt = event.date
    }

    var activeSessions: [SessionSnapshot] { tracker.active }

    var workingSessionCount: Int { tracker.workingCount }

    var subagentCount: Int { tracker.subagentCount }
}
